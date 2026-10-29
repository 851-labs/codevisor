import type { EventOccurrence } from "@codevisor/plugin-kit"

import { parseAddresses, sameAddress } from "./gmail-addresses.js"
import {
  type GmailApi,
  GmailApiError,
  type GmailHistoryPage,
  type GmailMessage
} from "./gmail-api.js"
import { decodeEntities } from "./gmail-body.js"
import { messageReceivedEvent } from "./gmail-event-catalog.js"
import { headerOf, receivedAt, senderOf } from "./gmail-message.js"

export interface CaughtUp {
  cursor: string
  truncated: boolean
  messages: ReadonlyArray<GmailMessage>
}

export const historyPageSize = 50
export const maxHistoryPages = 10

export const incomingSince = async (
  api: GmailApi,
  identity: string | undefined,
  cursor: string | null | undefined
): Promise<CaughtUp> => {
  if (cursor == null) return startFromNow(api, false)
  if (!historyIdPattern.test(cursor)) return startFromNow(api, true)

  const pages = await historyPages(api, cursor)
  if (pages === undefined) return startFromNow(api, true)

  const added = await addedMessages(api, pages.records)
  return {
    cursor: pages.cursor,
    truncated: false,
    messages: added.filter((message) => isIncoming(message, identity))
  }
}

export const receivedOccurrence = (message: GmailMessage, cursor: string): EventOccurrence => ({
  eventId: message.id,
  name: messageReceivedEvent,
  timestamp: receivedAt(message),
  data: receivedPayload(message),
  cursor
})

interface HistoryPages {
  cursor: string
  records: GmailHistoryPage["history"]
}

const historyIdPattern = /^\d+$/
const notFound = 404

const startFromNow = async (api: GmailApi, truncated: boolean): Promise<CaughtUp> => ({
  cursor: (await api.profile()).historyId,
  truncated,
  messages: []
})

const historyPages = async (api: GmailApi, start: string): Promise<HistoryPages | undefined> => {
  const records: GmailHistoryPage["history"] = []
  let cursor = start
  for (let page = 0; page < maxHistoryPages; page += 1) {
    const fetched = await unlessMissing(api.history(cursor, historyPageSize))
    if (fetched === undefined) return undefined

    records.push(...fetched.history)
    cursor = continuationOf(fetched)
    if (fetched.nextPageToken === undefined) break
  }
  return { cursor, records }
}

const continuationOf = (page: GmailHistoryPage): string => {
  const last = page.history.at(-1)
  if (page.nextPageToken === undefined || last === undefined) return page.historyId

  return last.id
}

const addedMessages = async (
  api: GmailApi,
  records: GmailHistoryPage["history"]
): Promise<Array<GmailMessage>> => {
  const ids = new Set(
    records.flatMap((record) => record.messagesAdded.map((added) => added.message.id))
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
  !sameAddress(senderOf(message), identity)

const receivedPayload = (message: GmailMessage): Record<string, unknown> => ({
  messageId: message.id,
  threadId: message.threadId,
  from: senderOf(message),
  to: emailsIn(headerOf(message, "To")),
  cc: emailsIn(headerOf(message, "Cc")),
  subject: headerOf(message, "Subject"),
  snippet: decodeEntities(message.snippet),
  labels: message.labelIds,
  receivedAt: receivedAt(message)
})

const emailsIn = (value: string): Array<string> =>
  parseAddresses(value).map((address) => address.email)
