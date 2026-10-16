import { AgentRuntimeError } from "@codevisor/agent-runtime"
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
import { isRecord } from "../unknown-values.js"
import { withCodevisorSkills } from "./prompt-skills.js"
import { beginPromptTurn, recordTurnStart } from "./prompt-turn.js"
import { materializeRuntimeEvent } from "./session-events.js"
import { ensureAgentSessionFor } from "./session-workspace.js"

export const hasLiveTurn = (routeState: RouteState, sessionId: string): boolean =>
  routeState.activePromptSessions.has(sessionId) || routeState.activeTurnSessions.has(sessionId)

const staleStreamingTurnQuietMs = 2 * 60 * 1000

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

export const makeTurnDispatchListener =
  (
    services: CodevisorServerServices,
    fanout: EventFanout,
    routeState: RouteState,
    serverId: string
  ) =>
  (event: EventEnvelope): void => {
    if (event.kind !== "session.updated" && event.kind !== "session.error") return
    const payload = isRecord(event.payload) ? event.payload : {}
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
  /* v8 ignore next */
  return { harnessId: session.harnessId, harnessName: catalogName ?? session.harnessId }
}

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
  if (routeState.restart.isGated()) {
    await holdForRestartDrain(services, fanout, routeState, sessionId)
    return
  }
  if (routeState.activePromptSessions.has(sessionId)) {
    await publishPromptQueue(services.db, fanout, sessionId)
    return
  }
  if (routeState.activeTurnSessions.has(sessionId)) {
    routeState.turnHeldSessions.add(sessionId)
    await publishPromptQueue(services.db, fanout, sessionId)
    return
  }
  const turn = await beginPromptTurn(services, routeState, sessionId)
  try {
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
      if (turn.isReleased()) return
      if (await sessionIsArchived(services, await run(services.db.getSessionSummary(sessionId))))
        return
      /* v8 ignore start */
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
      if (routeState.restart.isGated()) {
        await holdForRestartDrain(services, fanout, routeState, sessionId)
        return
      }
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
    await (clientId === undefined
      ? services.mcp?.beginTurn(sessionId)
      : services.mcp?.beginTurn(sessionId, { clientId }))
    await recordTurnStart(services, sessionId).catch(swallowError)
    const agentSession = await ensureAgentSessionFor(services, fanout, serverId, sessionId)
    const promptText = await withCodevisorSkills(services, sessionId, text, agentSession.skills)
    const input =
      refs.length === 0
        ? promptText
        : { attachments: await resolvePromptAttachments(services, refs), text: promptText }
    await run(services.agents.prompt(agentSession.sessionId, input))
  } catch (cause) {
    const signedOut = isAuthenticationFailure(cause)
    if (signedOut) {
      const session = await run(services.db.getSessionSummary(sessionId))
      /* v8 ignore next */
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
      ...(signedOut ? { stopKind: "authRequired" } : {}),
      serverId
    })
  }
}

const isAuthenticationFailure = (cause: unknown): boolean => {
  if (cause instanceof AgentRuntimeError && cause.authRequired === true) return true
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
