import {
  parseRemoteSessionKey,
  type AttachmentRef,
  type EventEnvelope,
  type SessionEventType,
  type SessionSubscription,
  type SessionSummary
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
import { isUpdatePause } from "../update-pauses.js"
import { conversationalBotForSession } from "./bot-turns.js"
import {
  erroredMessage,
  jobFinishedMessage,
  turnEndedMessage,
  waitingForUserMessage,
  type SessionEventMessage
} from "./session-event-messages.js"
import { makeSessionEventOutbox, type SessionEventOutbox } from "./session-event-outbox.js"

export interface SessionEventRouter {
  readonly listener: (event: EventEnvelope) => void
  readonly onJobFinished: (finished: ExecutionJobFinished) => void
}

export const finalAssistantText = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<{ readonly text: string; readonly attachments?: ReadonlyArray<AttachmentRef> }> => {
  const page = await run(services.db.getTranscriptPage(sessionId, undefined, FINAL_TEXT_PAGE))
  const item = [...page.items].toReversed().find((candidate) => candidate.role === "assistant")
  return {
    text: item?.text.trim() ?? "",
    ...(item?.attachments === undefined ? {} : { attachments: item.attachments })
  }
}

export const makeSessionEventRouter = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  afterTurnEnded: () => Promise<void>
): SessionEventRouter => {
  const outbox = makeSessionEventOutbox(services, fanout, routeState, serverId)
  const actionKinds = new Map<string, string | undefined>()
  const publish = makePublisher(services, outbox)

  const onTurnEnded = async (sessionId: string, payload: Record<string, unknown>) => {
    const target = await run(services.db.getSessionSummary(sessionId))
    const stopReason = typeof payload.stopReason === "string" ? payload.stopReason : undefined
    const final = await finalAssistantText(services, sessionId)
    await publish(target, "turn_ended", (subscriptionId) =>
      turnEndedMessage(target, stopReason, final.text, subscriptionId)
    )
    outbox.forgetWake(sessionId)
    await outbox.flushHeld(sessionId)
  }

  const onError = async (sessionId: string, message: string) => {
    const target = await run(services.db.getSessionSummary(sessionId))
    await publish(target, "errored", (subscriptionId) =>
      erroredMessage(target, message, subscriptionId)
    )
    await outbox.flushHeld(sessionId)
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
    const caller: Recipient = { subscriberId: owner.id, stale: collected }
    await publish(
      owner,
      "job_finished",
      (subscriptionId) => jobFinishedMessage(job, subscriptionId),
      [caller]
    )
  }

  const routeEvent = async (event: EventEnvelope, payload: Record<string, unknown>) => {
    if (event.kind === "session.updated" && payload.turnState === "ended") {
      if (isUpdatePause(payload)) {
        await outbox.flushHeld(event.subjectId)
        return
      }
      void afterTurnEnded().catch(swallowError)
      await onTurnEnded(event.subjectId, payload)
      return
    }
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
    },
    onJobFinished: (finished) => {
      void onJobFinished(finished).catch(swallowError)
    }
  }
}

const FINAL_TEXT_PAGE = 8

interface Recipient {
  readonly subscriberId: string
  readonly subscription?: SessionSubscription
  readonly stale?: () => boolean
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
        sourceSessionId: target.id,
        ...(recipient.stale === undefined ? {} : { stale: recipient.stale })
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
