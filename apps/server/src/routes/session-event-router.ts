import {
  parseRemoteSessionKey,
  type EventEnvelope,
  type SessionEventType,
  type SessionSubscription,
  type SessionSummary,
  type TranscriptBodyResource,
  type TranscriptItem
} from "@codevisor/api"
import type { ExecutionJobFinished } from "@codevisor/mcp"

import {
  run,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { isRecord } from "../unknown-values.js"
import { conversationalBotForSession } from "./bot-turns.js"
import {
  erroredMessage,
  jobFinishedMessage,
  turnEndedMessage,
  waitingForUserMessage,
  type SessionEventMessage,
  type TurnEnd
} from "./session-event-messages.js"
import { makeSessionEventOutbox, type SessionEventOutbox } from "./session-event-outbox.js"

export interface SessionEventRouter {
  readonly listener: (event: EventEnvelope) => void
  readonly onJobFinished: (finished: ExecutionJobFinished) => void
  readonly recover: () => Promise<void>
}

export const finalAssistantText = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<string> => (await latestTurnEnd(services, sessionId, undefined)).finalText

const latestTurnEnd = async (
  services: CodevisorServerServices,
  sessionId: string,
  stopReason: string | undefined
): Promise<TurnEnd> => {
  const item = await lastAssistantItem(services, sessionId, undefined)
  if (item === undefined) return { stopReason, finalText: "" }

  const finalText = (await completeText(services, sessionId, item)).trim()
  return { stopReason, finalText, usageLimitDetail: usageLimitDetailOf(item) }
}

const usageLimitDetailOf = (item: TranscriptItem): string | undefined =>
  item.stopKind === "usageLimit" ? item.stopDetail : undefined

export const makeSessionEventRouter = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  afterTurnFinished: () => Promise<void>
): SessionEventRouter => {
  const outbox = makeSessionEventOutbox(services, fanout, routeState, serverId)
  const actionKinds = new Map<string, string | undefined>()
  const publish = makePublisher(services, outbox)
  const announcements = new Map<string, Promise<void>>()

  const announceFinishedTurn = async (sessionId: string) => {
    const finished = await run(services.db.getFinishedTurn(sessionId))
    if (finished === undefined) return

    const target = await run(services.db.getSessionSummary(sessionId))
    const end = await latestTurnEnd(services, sessionId, finished.stopReason)
    await publish(target, "turn_ended", (subscriptionId) =>
      turnEndedMessage(target, end, subscriptionId)
    )
    await run(services.db.markTurnAnnounced(sessionId, finished.revision))
    outbox.forgetWake(sessionId)
    void afterTurnFinished().catch(swallowError)
  }

  const announceInOrder = (sessionId: string): Promise<void> => {
    const next = (announcements.get(sessionId) ?? Promise.resolve())
      .then(() => announceFinishedTurn(sessionId))
      .catch(swallowError)
    announcements.set(sessionId, next)
    void next.finally(() => {
      if (announcements.get(sessionId) === next) announcements.delete(sessionId)
    })
    return next
  }

  const onError = async (sessionId: string, message: string) => {
    const target = await run(services.db.getSessionSummary(sessionId))
    await publish(target, "errored", (subscriptionId) =>
      erroredMessage(target, message, subscriptionId)
    )
  }

  const onAttention = async (summary: Record<string, unknown>, sessionId: string) => {
    const kind =
      typeof summary.actionRequiredKind === "string" ? summary.actionRequiredKind : undefined
    const previous = actionKinds.get(sessionId)
    actionKinds.set(sessionId, kind)
    if (kind === undefined || kind === previous) return

    const target = await run(services.db.getSessionSummary(sessionId))
    const question = await run(services.db.getSessionPendingQuestion(sessionId))
    await publish(target, "waiting_for_user", (subscriptionId) =>
      waitingForUserMessage(target, kind, question, subscriptionId)
    )
  }

  const onJobFinished = async ({ job, collected }: ExecutionJobFinished) => {
    const owner = await run(services.db.getSessionSummary(job.sessionId)).catch(() => undefined)
    if (owner === undefined) return
    const caller: ReadonlyArray<Recipient> = collected() ? [] : [{ subscriberId: owner.id }]
    await publish(
      owner,
      "job_finished",
      (subscriptionId) => jobFinishedMessage(job, subscriptionId),
      caller
    )
  }

  const routeEvent = async (event: EventEnvelope, payload: Record<string, unknown>) => {
    if (event.kind === "session.error") {
      await onError(event.subjectId, String(payload.message))
      return
    }
    if (event.kind === "session.attention.updated") {
      await onAttention(payload, event.subjectId)
      return
    }
    if (isTypedUserPrompt(event, payload)) outbox.forgetWake(event.subjectId)
  }

  return {
    listener: (event) => {
      const payload = isRecord(event.payload) ? event.payload : {}
      void routeEvent(event, payload).catch(swallowError)
      if (event.kind.startsWith("session.")) void announceInOrder(event.subjectId)
    },
    onJobFinished: (finished) => {
      void onJobFinished(finished).catch(swallowError)
    },
    recover: async () => {
      const finished = await run(services.db.listFinishedTurns)
      await Promise.all(finished.map((turn) => announceInOrder(turn.sessionId)))
    }
  }
}

const FINAL_REPLY_PAGE = 32

interface Recipient {
  readonly subscriberId: string
  readonly subscription?: SessionSubscription
}

type BuildMessage = (subscriptionId?: string) => SessionEventMessage

const makePublisher =
  (services: CodevisorServerServices, outbox: SessionEventOutbox) =>
  async (
    target: SessionSummary,
    type: SessionEventType,
    build: BuildMessage,
    extra: ReadonlyArray<Recipient> = []
  ): Promise<void> => {
    const recipients = await recipientsFor(services, target, type, extra)
    for (const recipient of recipients) {
      if (pingPong(outbox, target, type, recipient)) continue
      if (recipient.subscription?.once === true) {
        await run(services.db.deleteSessionSubscription(recipient.subscription.id))
      }
      await outbox.deliver(recipient.subscriberId, {
        message: build(recipient.subscription?.id),
        sourceSessionId: target.id
      })
    }
  }

const recipientsFor = async (
  services: CodevisorServerServices,
  target: SessionSummary,
  type: SessionEventType,
  extra: ReadonlyArray<Recipient>
): Promise<ReadonlyArray<Recipient>> => {
  const explicit = (await run(services.db.listSubscriptionsTargeting(target.id)))
    .filter((subscription) => subscription.events.includes(type))
    .map((subscription) => ({ subscriberId: subscription.subscriberSessionId, subscription }))
  const implicit = [...extra, ...(await botParentRecipients(services, target, type))]
  const named = new Set(explicit.map((recipient) => recipient.subscriberId))
  return [...explicit, ...implicit.filter((recipient) => !named.has(recipient.subscriberId))]
}

const botParentRecipients = async (
  services: CodevisorServerServices,
  target: SessionSummary,
  type: SessionEventType
): Promise<ReadonlyArray<Recipient>> => {
  const parentSessionId = target.parentSessionId
  if (type !== "turn_ended" || parentSessionId === undefined) return []
  if (parseRemoteSessionKey(parentSessionId) !== undefined) return []
  const parentIsBot = (await conversationalBotForSession(services, parentSessionId)) !== undefined
  return parentIsBot ? [{ subscriberId: parentSessionId }] : []
}

const pingPong = (
  outbox: SessionEventOutbox,
  target: SessionSummary,
  type: SessionEventType,
  recipient: Recipient
): boolean => type === "turn_ended" && outbox.wokenBy(target.id).has(recipient.subscriberId)

const isTypedUserPrompt = (event: EventEnvelope, payload: Record<string, unknown>): boolean =>
  event.kind === "session.output" && payload.role === "user" && payload.origin !== "event"

const lastAssistantItem = async (
  services: CodevisorServerServices,
  sessionId: string,
  before: number | undefined
): Promise<TranscriptItem | undefined> => {
  const page = await run(services.db.getTranscriptPage(sessionId, before, FINAL_REPLY_PAGE))
  const item = page.items.findLast((candidate) => candidate.role === "assistant")
  if (item !== undefined || page.nextBefore === undefined) return item

  return lastAssistantItem(services, sessionId, Number(page.nextBefore))
}

const completeText = async (
  services: CodevisorServerServices,
  sessionId: string,
  item: TranscriptItem
): Promise<string> => {
  if (item.textResource === undefined) return item.text

  return (await textBodyFrom(services, sessionId, item.textResource, 0)).join("")
}

const textBodyFrom = async (
  services: CodevisorServerServices,
  sessionId: string,
  resource: TranscriptBodyResource,
  position: number
): Promise<ReadonlyArray<string>> => {
  const page = await run(
    services.db.getTranscriptBodyPage(
      sessionId,
      resource.itemId,
      resource.entryKey,
      "text",
      position
    )
  )
  /* v8 ignore next */
  if (page === undefined) return []
  if (page.nextPosition === undefined) return [page.text]

  return [page.text, ...(await textBodyFrom(services, sessionId, resource, page.nextPosition))]
}
