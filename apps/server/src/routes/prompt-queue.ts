import type { AttachmentRef, EventEnvelope, PromptQueueItem } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import { RESTART_GATE_HARNESS_ID, RESTART_GATE_HARNESS_NAME } from "../restart-drain.js"
import {
  appendAndPublish,
  failureMessage,
  resolvePromptAttachments,
  run,
  sessionIsArchived,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { materializeRuntimeEvent } from "./session-events.js"
import { ensureAgentSessionFor } from "./session-workspace.js"

export const reconcileOrphanedSessionTurns = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string
): Promise<void> => {
  const sessions = await run(services.db.listSessions)
  for (const session of sessions) {
    if (await sessionIsArchived(services, session)) {
      // Chats in an archived workspace get no turn restoration, but a stale
      // streaming row must still be closed — restoring the workspace would
      // otherwise resurface it as an endless in-progress turn.
      await run(services.db.closeStaleAssistantChatItems(session.id))
      continue
    }
    const page = await run(services.db.getTranscriptPage(session.id, undefined, 1))
    const active = page.items.at(-1)
    const hasOrphanedTurn = active?.role === "assistant" && active.isGenerating
    // Reconciliation runs before the server accepts clients, so no live turn
    // exists anywhere: every streaming row is dead. The newest item is closed
    // by the turn-ending path below with full restore context; older rows —
    // stranded mid-transcript when a previous process died or a concurrent
    // writer stole the projection pointer — would otherwise render as an
    // endless in-progress turn that no future event can ever finish. Like
    // the runtime sweep, this is invisible housekeeping: the text that
    // arrived settles as an ordinary finished response. A restart is not the
    // user's problem to act on, and the chat reconnects its agent session
    // the moment it is next opened.
    await run(
      services.db.closeStaleAssistantChatItems(session.id, hasOrphanedTurn ? active.id : undefined)
    )
    // The database projection always supplies the full background-task
    // snapshot; the API field is optional only for older remote clients.
    const hasOrphanedTasks = page.backgroundTasks!.length > 0
    const claimedPrompts = await run(services.db.listProcessingPromptQueue(session.id))
    const processingPrompts: Array<PromptQueueItem> = []
    for (const item of claimedPrompts) {
      if (await run(services.db.hasTerminalAssistantAfterMessage(session.id, item.id))) {
        // The provider finished and only the queue acknowledgement was lost.
        // Its terminal chat row is sufficient proof that replay is unnecessary.
        await run(services.db.completePromptQueueItem(session.id, item.id))
      } else {
        processingPrompts.push(item)
      }
    }
    if (!hasOrphanedTurn && !hasOrphanedTasks && processingPrompts.length === 0) continue

    // The provider-side resolver vanished with the old process. Pair a
    // persisted question before ending the turn so event replay never leaves
    // an apparently answerable request behind.
    if (hasOrphanedTurn && page.pendingQuestion !== undefined) {
      await appendAndPublish(services.db, fanout, "session.output", session.id, {
        outcome: "cancelled",
        questionId: page.pendingQuestion.questionId,
        questions: page.pendingQuestion.questions,
        sessionUpdate: "question_resolved",
        serverId
      })
    }

    // Process-owned background tasks cannot survive the same crash. Publish a
    // full empty snapshot before the terminal event so another crash can never
    // persist the terminal row while leaving stale work behind. If startup
    // dies between these appends, the still-generating turn is reconciled again.
    if (hasOrphanedTasks) {
      await appendAndPublish(services.db, fanout, "session.updated", session.id, {
        backgroundTasks: [],
        serverId
      })
    }
    // A prompt remains durably claimed until its provider call finishes. If
    // the process died while dispatching it, make sure the user's input is
    // represented exactly once, then close a deterministic turn for it when the
    // provider had not emitted one yet. The claim is acknowledged
    // only after another durable generating row exists, so every crash point
    // leaves at least one marker for the next startup pass to reconcile.
    for (const item of processingPrompts) {
      if (!(await run(services.db.hasConversationMessage(session.id, item.id)))) {
        await appendAndPublish(services.db, fanout, "session.output", session.id, {
          role: "user",
          messageId: item.id,
          text: item.text,
          ...(item.attachments === undefined ? {} : { attachments: item.attachments }),
          serverId
        })
      }
    }

    let terminalTurnId = hasOrphanedTurn ? active.turnId : undefined
    if (!hasOrphanedTurn && processingPrompts.length > 0) {
      terminalTurnId = `recovered-prompt:${processingPrompts[0]!.id}`
      await appendAndPublish(services.db, fanout, "session.updated", session.id, {
        initiatedBy: "user",
        turnId: terminalTurnId,
        turnState: "started",
        serverId
      })
    }
    for (const item of processingPrompts) {
      await run(services.db.completePromptQueueItem(session.id, item.id))
    }

    if (!hasOrphanedTurn && terminalTurnId === undefined) continue

    await appendAndPublish(services.db, fanout, "session.updated", session.id, {
      ...(terminalTurnId === undefined
        ? {}
        : { initiatedBy: "user", turnId: terminalTurnId, turnState: "ended" }),
      serverId,
      stopReason: "end_turn"
    })
  }
}

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
  serverId: string
): Promise<number> => {
  const cutoff = new Date(Date.now() - staleStreamingTurnQuietMs).toISOString()
  const staleSessions = await run(services.db.listQuietStreamingSessions(cutoff))
  let repaired = 0
  for (const sessionId of staleSessions) {
    // A live turn is never touched, however quiet: long silent tool runs and
    // subagent waits are normal, and the turn's own terminal event (or the
    // adapter's stream-death handling) will close it.
    if (hasLiveTurn(routeState, sessionId)) continue
    const page = await run(services.db.getTranscriptPage(sessionId, undefined, 1))
    const active = page.items.at(-1)
    const hasOrphanedTurn = active?.role === "assistant" && active.isGenerating

    // Pair a persisted question before ending the turn so event replay never
    // leaves an apparently answerable request behind (mirrors startup
    // reconciliation — the resolver died with the turn).
    if (hasOrphanedTurn && page.pendingQuestion !== undefined) {
      await appendAndPublish(services.db, fanout, "session.output", sessionId, {
        outcome: "cancelled",
        questionId: page.pendingQuestion.questionId,
        questions: page.pendingQuestion.questions,
        sessionUpdate: "question_resolved",
        serverId
      })
    }

    repaired += await run(
      services.db.closeStaleAssistantChatItems(sessionId, hasOrphanedTurn ? active.id : undefined)
    )
    if (!hasOrphanedTurn) continue

    // End the newest turn through the normal event pipeline so connected
    // clients receive the terminal event live instead of discovering the
    // repaired row on their next full reload.
    await appendAndPublish(services.db, fanout, "session.updated", sessionId, {
      ...(active.turnId === undefined
        ? {}
        : { initiatedBy: "user", turnId: active.turnId, turnState: "ended" }),
      serverId,
      stopReason: "end_turn"
    })
    repaired += 1
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
  routeState.activePromptSessions.add(sessionId)
  // Turn accounting for update-when-idle: the lifecycle manager runs armed
  // updates when a harness's last in-flight turn ends.
  const busyHarnessId = await run(services.db.getSessionSummary(sessionId))
    .then((session) => session.harnessId)
    .catch(swallowError)
  /* v8 ignore next -- defensive: unknown sessions simply skip turn accounting. */
  if (busyHarnessId !== undefined) services.lifecycle?.notifyTurnStarted(busyHarnessId)
  try {
    while (true) {
      if (await sessionIsArchived(services, await run(services.db.getSessionSummary(sessionId))))
        return
      // A gate that closed mid-drain (Update Now) holds the *next* item —
      // registering the session so the release re-drains what remains.
      /* v8 ignore start -- timing-dependent: requires the gate to close between
         two queue claims. The hold/release semantics are covered by the
         pre-drain gate path and the lifecycle manager's gating tests. */
      if (
        services.lifecycle !== undefined &&
        busyHarnessId !== undefined &&
        services.lifecycle.isGated(busyHarnessId)
      ) {
        const firstHold = !routeState.gatedSessions.has(sessionId)
        routeState.gatedSessions.set(sessionId, busyHarnessId)
        if (firstHold) {
          const harnessName =
            services.agents.catalog.find((definition) => definition.id === busyHarnessId)?.name ??
            busyHarnessId
          await appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
            harnessId: busyHarnessId,
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
        item.attachments
      )
      await run(services.db.completePromptQueueItem(sessionId, item.id))
    }
  } finally {
    routeState.activePromptSessions.delete(sessionId)
    /* v8 ignore next -- defensive: unknown sessions simply skip turn accounting. */
    if (busyHarnessId !== undefined) services.lifecycle?.notifyTurnEnded(busyHarnessId)
  }
}

const runPromptInBackground = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  queueItemId: string,
  text: string,
  attachments?: ReadonlyArray<AttachmentRef>
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
    await services.mcp?.beginTurn(sessionId)
    const agentSession = await ensureAgentSessionFor(services, fanout, serverId, sessionId)
    // Session output, turn lifecycle, and the final stopReason all flow
    // through the standing sink registered at session create/load time.
    const input =
      refs.length === 0
        ? text
        : { attachments: await resolvePromptAttachments(services, refs), text }
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
