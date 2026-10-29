import { AgentRuntimeError, harnessFailureKind, plainFailureText } from "@codevisor/agent-runtime"
import type {
  AttachmentRef,
  ConnectedClient,
  EventEnvelope,
  PromptAttribution,
  PromptOrigin,
  PromptQueueItem
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"

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
import { conversationalBotForSession } from "./bot-turns.js"
import { coalesceWakeUps, heldForUsageLimit } from "./bot-usage-hold.js"
import { withConversationRecap } from "./conversation-recap.js"
import {
  markAppContextsDelivered,
  withAppContexts,
  type AppContextPrompt
} from "./prompt-app-context.js"
import { withCodevisorSkills } from "./prompt-skills.js"
import { beginPromptTurn, recordTurnStart } from "./prompt-turn.js"
import { answeredPendingQuestion } from "./question-replies.js"
import { ensureAgentSessionFor } from "./session-workspace.js"
import { pausedForUpdate, sessionHarnessId } from "./update-pause-gate.js"
import { recordUserPrompt, steeredPrompt } from "./user-prompts.js"

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
  const gate = routeState.restart.gateFor(await sessionHarnessId(services, sessionId))
  routeState.restartHeldSessions.set(sessionId, gate)
  await publishPromptQueue(services.db, fanout, sessionId)
  if (firstHold) {
    await appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
      ...gate,
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
  if (await pausedForUpdate(services, routeState, sessionId)) {
    await holdForRestartDrain(services, fanout, routeState, sessionId)
    return
  }
  if (routeState.updateResume.isPending(sessionId)) {
    await publishPromptQueue(services.db, fanout, sessionId)
    return
  }
  if (routeState.activePromptSessions.has(sessionId)) {
    await steerQueuedPrompts(services, fanout, routeState, serverId, sessionId)
    await publishPromptQueue(services.db, fanout, sessionId)
    return
  }
  if (routeState.activeTurnSessions.has(sessionId)) {
    routeState.turnHeldSessions.add(sessionId)
    await steerQueuedPrompts(services, fanout, routeState, serverId, sessionId)
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
      if (routeState.restart.gates(turn.harnessId)) {
        await holdForRestartDrain(services, fanout, routeState, sessionId)
        return
      }
      if (routeState.activeTurnSessions.has(sessionId)) {
        routeState.turnHeldSessions.add(sessionId)
        await publishPromptQueue(services.db, fanout, sessionId)
        return
      }
      if (await heldForUsageLimit(services, sessionId)) {
        await publishPromptQueue(services.db, fanout, sessionId)
        return
      }
      const item = await onSteerChain(sessionId, async () => {
        await coalesceWakeUps(services, sessionId)
        return run(services.db.claimPromptQueueItem(sessionId))
      })
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
        item.clientId === undefined
          ? undefined
          : { clientId: item.clientId, platform: clientPlatform(routeState, item.clientId) },
        item.origin,
        item.attribution
      )
      await run(services.db.completePromptQueueItem(sessionId, item.id))
    }
  } finally {
    turn.release()
  }
}

const steerChains = new Map<string, Promise<unknown>>()

const onSteerChain = <A>(sessionId: string, task: () => Promise<A>): Promise<A> => {
  const next = (steerChains.get(sessionId) ?? Promise.resolve()).then(task)
  const settled = next.catch(swallowError)
  steerChains.set(sessionId, settled)
  void settled.finally(() => {
    if (steerChains.get(sessionId) === settled) steerChains.delete(sessionId)
  })
  return next
}

const steerQueuedPrompts = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  sessionId: string
): Promise<void> =>
  onSteerChain(sessionId, () =>
    steerPendingPrompts(services, fanout, routeState, serverId, sessionId)
  ).catch(swallowError)

export const steerQueuedPrompt = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  queueItemId: string
): Promise<boolean> =>
  onSteerChain(sessionId, async () => {
    const item = await run(services.db.claimPromptQueueItem(sessionId, queueItemId))
    /* v8 ignore next */
    if (item === undefined) return false
    return steerClaimedPrompt(services, fanout, serverId, sessionId, item)
  })

export const steerQueuedPromptsThrough = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  queueItemId: string
): Promise<boolean> =>
  onSteerChain(sessionId, async () => {
    const queue = await run(services.db.listPromptQueue(sessionId))
    const through = queue.findIndex((item) => item.id === queueItemId)
    for (const queued of queue.slice(0, through + 1)) {
      const item = await run(services.db.claimPromptQueueItem(sessionId, queued.id))
      /* v8 ignore next */
      if (item === undefined) return false
      if (!(await steerClaimedPrompt(services, fanout, serverId, sessionId, item))) return false
    }
    return through !== -1
  })

const steerPendingPrompts = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  sessionId: string
): Promise<void> => {
  if ((await conversationalBotForSession(services, sessionId)) === undefined) return
  while (true) {
    const item = await run(services.db.claimPromptQueueItem(sessionId))
    if (item === undefined) return
    if (await steerClaimedPrompt(services, fanout, serverId, sessionId, item)) continue

    if (!hasLiveTurn(routeState, sessionId)) {
      void drainPromptQueue(services, fanout, routeState, serverId, sessionId).catch(swallowError)
    }
    return
  }
}

const steerClaimedPrompt = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  item: PromptQueueItem
): Promise<boolean> => {
  if (await answeredPendingQuestion(services, fanout, serverId, sessionId, item)) {
    await run(services.db.completePromptQueueItem(sessionId, item.id))
    return true
  }

  const steered = await steerIntoRunningTurn(services, fanout, serverId, sessionId, item).catch(
    () => false
  )
  if (!steered) {
    await run(services.db.releasePromptQueueItem(sessionId, item.id))
    return false
  }

  await recordUserPrompt(services, fanout, serverId, sessionId, steeredPrompt(item))
  await run(services.db.completePromptQueueItem(sessionId, item.id))
  return true
}

const steerIntoRunningTurn = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  item: PromptQueueItem
): Promise<boolean> => {
  const steer = services.agents.steer
  /* v8 ignore next */
  if (steer === undefined) return false

  const agentSession = await ensureAgentSessionFor(services, fanout, serverId, sessionId)
  const prompt = await promptInput(services, sessionId, item, agentSession.skills)
  const steered = await run(steer(agentSession.sessionId, prompt.input))
  if (steered) await markAppContextsDelivered(services, sessionId, prompt.delivered)
  return steered
}

const promptInput = async (
  services: CodevisorServerServices,
  sessionId: string,
  item: Pick<PromptQueueItem, "text" | "attachments" | "origin">,
  skills: Parameters<typeof withCodevisorSkills>[3]
) => {
  const refs = item.attachments ?? []
  const prompt = await promptText(services, sessionId, item, skills)
  if (refs.length === 0) return { input: prompt.text, delivered: prompt.delivered }
  const attachments = await resolvePromptAttachments(services, refs)
  return { input: { attachments, text: prompt.text }, delivered: prompt.delivered }
}

const promptText = async (
  services: CodevisorServerServices,
  sessionId: string,
  item: Pick<PromptQueueItem, "text" | "origin">,
  skills: Parameters<typeof withCodevisorSkills>[3]
): Promise<AppContextPrompt> => {
  const text = withConversationRecap(services, sessionId, item.text)
  if (item.origin === "system") return { text, delivered: [] }
  const typed = await withCodevisorSkills(services, sessionId, text, skills)
  return withAppContexts(services, sessionId, typed)
}

const clientPlatform = (
  routeState: RouteState,
  clientId: string
): ConnectedClient["platform"] | undefined =>
  routeState.clientControl
    ?.list()
    .find((client) => client.clientId.toLowerCase() === clientId.toLowerCase())?.platform

const runPromptInBackground = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  queueItemId: string,
  text: string,
  attachments?: ReadonlyArray<AttachmentRef>,
  client?: {
    readonly clientId: string
    readonly platform: ConnectedClient["platform"] | undefined
  },
  origin?: PromptOrigin,
  attribution?: PromptAttribution
): Promise<void> => {
  try {
    await recordUserPrompt(services, fanout, serverId, sessionId, {
      messageId: queueItemId,
      text,
      attachments,
      origin,
      attribution,
      startsTurn: true
    })
    if (client === undefined) {
      await services.mcp?.beginTurn(sessionId)
    } else {
      await services.mcp?.beginTurn(sessionId, {
        clientId: client.clientId,
        ...(client.platform === undefined ? {} : { clientPlatform: client.platform })
      })
    }
    await recordTurnStart(services, sessionId).catch(swallowError)
    const agentSession = await ensureAgentSessionFor(services, fanout, serverId, sessionId)
    const prompt = await promptInput(
      services,
      sessionId,
      {
        text,
        ...(attachments === undefined ? {} : { attachments }),
        ...(origin === undefined ? {} : { origin })
      },
      agentSession.skills
    )
    await run(services.agents.prompt(agentSession.sessionId, prompt.input))
    await markAppContextsDelivered(services, sessionId, prompt.delivered)
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
    const message = plainFailureText(failureMessage(cause))
    await appendAndPublish(services.db, fanout, "session.error", sessionId, {
      message,
      stopKind: signedOut ? "authRequired" : harnessFailureKind({ message }),
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
