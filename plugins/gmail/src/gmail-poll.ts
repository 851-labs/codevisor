import type { EventOccurrence, EventsPollParams } from "@codevisor/plugin-kit"

import {
  type GmailApi,
  GmailApiError,
  type GmailHistoryPage,
  type GmailMessage
} from "./gmail-api.js"
import { messageReceivedEvent } from "./gmail-catalog.js"
import { type MessageSummary, messageSummary } from "./gmail-message.js"

export type PolledEvent = Omit<EventOccurrence, "cursor">

export interface PollResult {
  [key: string]: unknown
  resultType: "complete"
  events: ReadonlyArray<PolledEvent>
  cursor: string
  truncated: boolean
  hasMore: boolean
  nextPollMs: number
}

export const gmailPollDefaults = { nextPollMs: 30_000, maxEvents: 25, maxEventsCap: 50 } as const

export const pollMessages = async (
  api: GmailApi,
  identity: string | undefined,
  request: EventsPollParams,
  now: number
): Promise<PollResult> => {
  if (request.cursor == null) return startFromNow(api, false)
  if (!historyIdPattern.test(request.cursor)) return startFromNow(api, true)

  const page = await unlessMissing(api.history(request.cursor, pageSize(request.maxEvents)))
  if (page === undefined) return startFromNow(api, true)

  const incoming = (await addedMessages(api, page)).filter((message) =>
    isIncoming(message, identity)
  )
  const recent = incoming.filter((message) => withinAge(message, request.maxAgeMs, now))
  return {
    ...continuation(page),
    events: recent.map(receivedEvent),
    truncated: recent.length < incoming.length
  }
}

interface Continuation {
  resultType: "complete"
  cursor: string
  hasMore: boolean
  nextPollMs: number
}

const historyIdPattern = /^\d+$/
const notFound = 404

const startFromNow = async (api: GmailApi, truncated: boolean): Promise<PollResult> => {
  const profile = await api.profile()
  return { ...settled(profile.historyId, false), events: [], truncated }
}

const settled = (cursor: string, hasMore: boolean): Continuation => ({
  resultType: "complete",
  cursor,
  hasMore,
  nextPollMs: gmailPollDefaults.nextPollMs
})

const pageSize = (maxEvents: number | undefined): number =>
  Math.min(maxEvents ?? gmailPollDefaults.maxEvents, gmailPollDefaults.maxEventsCap)

const addedMessages = async (
  api: GmailApi,
  page: GmailHistoryPage
): Promise<Array<GmailMessage>> => {
  const ids = new Set(
    page.history.flatMap((record) => record.messagesAdded.map((added) => added.message.id))
  )
  const messages = await Promise.all(
    [...ids].map((id) => unlessMissing(api.message(id, "metadata")))
  )
  return messages.filter((message) => message !== undefined)
}

const unlessMissing = async <T>(request: Promise<T>): Promise<T | undefined> => {
  try {
    return await request
  } catch (error) {
    if (error instanceof GmailApiError && error.status === notFound) return undefined
    throw error
  }
}

const isIncoming = (message: GmailMessage, identity: string | undefined): boolean =>
  message.labelIds.includes("INBOX") &&
  !message.labelIds.includes("SENT") &&
  !sentBy(message, identity)

const sentBy = (message: GmailMessage, identity: string | undefined): boolean =>
  identity !== undefined && messageSummary(message).from.email === identity.toLowerCase()

const withinAge = (message: GmailMessage, maxAgeMs: number | undefined, now: number): boolean =>
  maxAgeMs === undefined || Number(message.internalDate) >= now - maxAgeMs

const continuation = (page: GmailHistoryPage): Continuation => {
  const last = page.history.at(-1)
  if (page.nextPageToken === undefined || last === undefined) return settled(page.historyId, false)

  return settled(last.id, true)
}

const receivedEvent = (message: GmailMessage): PolledEvent => {
  const summary = messageSummary(message)
  return {
    eventId: message.id,
    name: messageReceivedEvent,
    timestamp: summary.receivedAt,
    data: receivedPayload(summary)
  }
}

const receivedPayload = (summary: MessageSummary): Record<string, unknown> => ({
  messageId: summary.id,
  threadId: summary.threadId,
  from: summary.from,
  to: summary.to,
  cc: summary.cc,
  subject: summary.subject,
  snippet: summary.snippet,
  labels: summary.labels,
  receivedAt: summary.receivedAt
})
