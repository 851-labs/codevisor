import type { AttachmentRef, EventEnvelope, PromptQueueItem } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"

import { RESTART_GATE_HARNESS_ID, RESTART_GATE_HARNESS_NAME } from "../restart-drain.js"
import {
  appendAndPublish,
  failureMessage,
  forgetTurnIfArchived,
  resolvePromptAttachments,
  run,
  sessionIsArchived,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { withCodevisorSkills } from "./prompt-skills.js"
import { beginPromptTurn, recordTurnStart } from "./prompt-turn.js"
import { materializeRuntimeEvent } from "./session-events.js"
import { ensureAgentSessionFor } from "./session-workspace.js"

/// Whether this process knows the session's newest turn to be alive: either a
/// prompt drain dispatched it (`activePromptSessions`) or its `turnState:
/// started` event was observed on the fanout (`activeTurnSessions`, which also
/// covers turns the harness starts on its own — a task-notification follow-up
/// after a background task or subagent finishes). Liveness is tracked, never
/// inferred from event timing: a turn quiet for ten minutes inside one long
/// tool call is still alive.
export const hasLiveTurn = (routeState: RouteState, sessionId: string): boolean =>
  routeState.activePromptSessions.has(sessionId) || routeState.activeTurnSessions.has(sessionId)

/// How long a session's event log must be quiet before an unowned
/// still-streaming assistant row is treated as orphaned. Ownership
/// (`hasLiveTurn`) is the real criterion; this window only absorbs the race
/// between a row appearing in the database and its turn registering in
/// process memory, so it can be short — stuck rows heal sooner.
const staleStreamingTurnQuietMs = 2 * 60 * 1000

/// The runtime counterpart of `reconcileOrphanedSessionTurns`: that pass heals
/// rows stranded by a dead *process* at startup, this one heals rows stranded
/// by a dead *turn* while the server keeps running (lost terminal event, a
/// terminal write that failed). Without it, a stuck `streaming` row renders as
/// an endless in-progress turn to every client — including freshly relaunched
/// ones — until the next server restart.
///
/// Healing is invisible housekeeping: the row settles as an ordinary finished
/// response and the turn ends with a plain `end_turn`. There is nothing for
/// the user to do about a lost event, so nothing is rendered about it — the
/// text that arrived simply stops being "in progress". Returns the number of
/// repaired rows.
export const reconcileStaleStreamingTurns = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  _serverId: string
): Promise<number> => {
  const cutoff = new Date(Date.now() - staleStreamingTurnQuietMs).toISOString()
  const staleSessions = await run(services.db.listQuietStreamingSessions(cutoff))
  let repaired = 0
  for (const sessionId of staleSessions) {
    // A live turn is never touched, however quiet: long silent tool runs and
    // subagent waits are normal, and the turn's own terminal event (or the
    // adapter's stream-death handling) will close it.
    repaired += await run(
      Effect.suspend(() => {
        if (hasLiveTurn(routeState, sessionId)) return Effect.succeed(0)
        return Effect.flatMap(
          services.db.reconcileQuietStreamingSession(sessionId, cutoff),
          (result) =>
            Effect.as(
              Effect.forEach(result.events, (event) => fanout.publish(event)),
              result.repaired
            )
        )
      })
    )
  }
  return repaired
}

export const publishPromptQueue = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  sessionId: string
): Promise<ReadonlyArray<PromptQueueItem>> => {
  const queue = await run(db.listPromptQueue(sessionId))
  await appendAndPublish(db, fanout, "session.queue.updated", sessionId, { queue })
  return queue
}

/// Fanout listener that keeps `routeState.activeTurnSessions` current from
/// turn lifecycle events. Unlike `activePromptSessions` (turns this process
/// dispatched itself), this also sees turns the harness starts on its own —
/// a task-notification follow-up after a background task finishes — so
/// prompt dispatch can hold instead of injecting into the live turn.
/// Terminal events re-drain any session whose dispatch was held. Synthetic
/// terminal events (startup/stale-turn reconciliation) ride the same fanout,
/// so a crashed harness can never wedge the hold.
export const makeTurnDispatchListener =
  (
    services: CodevisorServerServices,
    fanout: EventFanout,
    routeState: RouteState,
    serverId: string
  ) =>
  (event: EventEnvelope): void => {
    if (event.kind !== "session.updated" && event.kind !== "session.error") return
    const payload =
      typeof event.payload === "object" && event.payload !== null && !Array.isArray(event.payload)
        ? (event.payload as Record<string, unknown>)
        : {}
    if (event.kind === "session.updated" && payload.turnState === "started") {
      routeState.activeTurnSessions.add(event.subjectId)
      void forgetTurnIfArchived(services, routeState, event.subjectId).catch(swallowError)
      return
    }
    const terminal =
      event.kind === "session.error" ||
      payload.turnState === "ended" ||
      typeof payload.stopReason === "string"
    if (!terminal) return
    routeState.activeTurnSessions.delete(event.subjectId)
    if (routeState.turnHeldSessions.delete(event.subjectId)) {
      void drainPromptQueue(services, fanout, routeState, serverId, event.subjectId).catch(
        swallowError
      )
    }
  }

/// The session's harness id + display name when its harness update gate is
/// closed; undefined when dispatch may proceed. Failures resolve open — a
/// lookup error must never wedge prompt dispatch.
const sessionUpdateGate = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<{ readonly harnessId: string; readonly harnessName: string } | undefined> => {
  const lifecycle = services.lifecycle
  if (lifecycle === undefined) return undefined
  const session = await run(services.db.getSessionSummary(sessionId)).catch(swallowError)
  if (session === undefined || !lifecycle.isGated(session.harnessId)) return undefined
  const catalogName = services.agents.catalog.find(
    (definition) => definition.id === session.harnessId
  )?.name
  /* v8 ignore next -- defensive: sessions on uncataloged harnesses fall back to the id. */
  return { harnessId: session.harnessId, harnessName: catalogName ?? session.harnessId }
}

/// Restart-drain gate: while the server waits for live turns to end before
/// restarting for an update, new prompts stay durable in the queue and are
/// simply not claimed. The next boot (or a cancelled drain) re-drains every
/// held session. Callers check `restart.isGated()` first.
const holdForRestartDrain = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  sessionId: string
): Promise<void> => {
  const firstHold = !routeState.restartHeldSessions.has(sessionId)
  routeState.restartHeldSessions.add(sessionId)
  await publishPromptQueue(services.db, fanout, sessionId)
  if (firstHold) {
    await appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
      harnessId: RESTART_GATE_HARNESS_ID,
      harnessName: RESTART_GATE_HARNESS_NAME,
      state: "waiting"
    }).catch(swallowError)
  }
}

export const drainPromptQueue = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  sessionId: string
): Promise<void> => {
  // Checked before the in-flight holds below: while the server drains for a
  // restart, a prompt queued behind a live turn must also learn it will wait
  // for the restart, not just for that turn. The gate test itself is
  // synchronous on purpose — an await here would let two concurrent drains
  // for one session both pass the in-flight check below.
  if (routeState.restart.isGated()) {
    await holdForRestartDrain(services, fanout, routeState, sessionId)
    return
  }
  if (routeState.activePromptSessions.has(sessionId)) {
    // This item really is waiting behind an in-flight prompt, so expose it to
    // clients as queued. The first prompt takes the owner path below and is
    // claimed before any queue snapshot is published; otherwise every normal
    // send briefly flashes as a one-item queue before execution starts.
    await publishPromptQueue(services.db, fanout, sessionId)
    return
  }
  // A turn the harness started on its own (a task-notification follow-up
  // after a background task finished) has no prompt drain to queue behind —
  // without this hold the prompt would dispatch straight into the busy
  // harness, and the active turn's terminal event would resolve it before it
  // ever ran. Hold exactly like a queued-behind-a-drain prompt; the turn's
  // terminal event re-drains via the fanout listener.
  if (routeState.activeTurnSessions.has(sessionId)) {
    routeState.turnHeldSessions.add(sessionId)
    await publishPromptQueue(services.db, fanout, sessionId)
    return
  }
  // Own the drain before a gate or summary lookup can yield.
  const turn = await beginPromptTurn(services, routeState, sessionId)
  try {
    // Harness-update gate: the prompt is already durable in prompt_queue_items
    // and the client has its 202 — holding is simply not claiming. The gate
    // release listener re-drains every held session.
    const gate = await sessionUpdateGate(services, sessionId)
    if (gate !== undefined) {
      const firstHold = !routeState.gatedSessions.has(sessionId)
      routeState.gatedSessions.set(sessionId, gate.harnessId)
      await publishPromptQueue(services.db, fanout, sessionId)
      if (firstHold) {
        await appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
          harnessId: gate.harnessId,
          harnessName: gate.harnessName,
          state: "waiting"
        }).catch(swallowError)
      }
      return
    }
    while (true) {
      // Released by a retire: a newer drain may already own this session
      // (the chat was unarchived and prompted again), so this one stops.
      if (turn.isReleased()) return
      if (await sessionIsArchived(services, await run(services.db.getSessionSummary(sessionId))))
        return
      // A gate that closed mid-drain (Update Now) holds the *next* item —
      // registering the session so the release re-drains what remains.
      /* v8 ignore start -- timing-dependent: requires the gate to close between
         two queue claims. The hold/release semantics are covered by the
         pre-drain gate path and the lifecycle manager's gating tests. */
      if (
        services.lifecycle !== undefined &&
        turn.harnessId !== undefined &&
        services.lifecycle.isGated(turn.harnessId)
      ) {
        const firstHold = !routeState.gatedSessions.has(sessionId)
        routeState.gatedSessions.set(sessionId, turn.harnessId)
        if (firstHold) {
          const harnessName =
            services.agents.catalog.find((definition) => definition.id === turn.harnessId)?.name ??
            turn.harnessId
          await appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
            harnessId: turn.harnessId,
            harnessName,
            state: "waiting"
          }).catch(() => undefined)
        }
        return
      }
      /* v8 ignore stop */
      // A restart drain that began mid-drain holds the *next* item the same
      // way: this session's finished turn is exactly what the drain waited
      // for, and claiming another would keep the server busy forever.
      if (routeState.restart.isGated()) {
        await holdForRestartDrain(services, fanout, routeState, sessionId)
        return
      }
      // Same hold mid-drain: a task-notification turn can begin between one
      // claimed prompt finishing and the next claim. Dispatching the next
      // item into that live turn would recreate the interleave this hold
      // exists to prevent.
      if (routeState.activeTurnSessions.has(sessionId)) {
        routeState.turnHeldSessions.add(sessionId)
        await publishPromptQueue(services.db, fanout, sessionId)
        return
      }
      const item = await run(services.db.claimPromptQueueItem(sessionId))
      if (item === undefined) {
        await publishPromptQueue(services.db, fanout, sessionId)
        return
      }
      await publishPromptQueue(services.db, fanout, sessionId)
      await runPromptInBackground(
        services,
        fanout,
        serverId,
        sessionId,
        item.id,
        item.text,
        item.attachments,
        item.clientId
      )
      await run(services.db.completePromptQueueItem(sessionId, item.id))
    }
  } finally {
    turn.release()
  }
}

const runPromptInBackground = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  queueItemId: string,
  text: string,
  attachments?: ReadonlyArray<AttachmentRef>,
  clientId?: string
): Promise<void> => {
  try {
    const refs = attachments ?? []
    await materializeRuntimeEvent(
      services.db,
      fanout,
      serverId,
      {
        kind: "session.output",
        subjectId: sessionId,
        payload: {
          role: "user",
          messageId: queueItemId,
          startsTurn: true,
          text,
          ...(refs.length === 0 ? {} : { attachments: refs })
        }
      },
      sessionId
    )
    // Queued prompts start a new response. Steering input never passes here,
    // so a preference edit cannot replace the browser under a running agent.
    // The originating window lets gateway scripts tell which client asked.
    await (clientId === undefined
      ? services.mcp?.beginTurn(sessionId)
      : services.mcp?.beginTurn(sessionId, { clientId }))
    await recordTurnStart(services, sessionId).catch(swallowError)
    const agentSession = await ensureAgentSessionFor(services, fanout, serverId, sessionId)
    const promptText = await withCodevisorSkills(services, sessionId, text, agentSession.skills)
    // Session output, turn lifecycle, and the final stopReason all flow
    // through the standing sink registered at session create/load time.
    const input =
      refs.length === 0
        ? promptText
        : { attachments: await resolvePromptAttachments(services, refs), text: promptText }
    await run(services.agents.prompt(agentSession.sessionId, input))
  } catch (cause) {
    if (isAuthenticationFailure(cause)) {
      const session = await run(services.db.getSessionSummary(sessionId))
      /* v8 ignore next -- auth failures on pinned and legacy sessions are integration-tested. */
      if (session.harnessAccountId !== undefined) {
        await services.auth?.markAccountExpired(session.harnessAccountId, failureMessage(cause))
      }
      await appendAndPublish(services.db, fanout, "session.authRequired", sessionId, {
        detail: failureMessage(cause),
        serverId
      })
    }
    await appendAndPublish(services.db, fanout, "session.error", sessionId, {
      message: failureMessage(cause),
      serverId
    })
  }
}

const isAuthenticationFailure = (cause: unknown): boolean => {
  const message = failureMessage(cause).toLowerCase()
  return (
    message.includes("authentication") ||
    message.includes("unauthorized") ||
    message.includes("not logged in") ||
    message.includes("sign-in") ||
    message.includes("sign in") ||
    message.includes("token expired")
  )
}
