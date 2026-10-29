import { parseAddresses, type MailAddress } from "./gmail-addresses.js"
import type { GmailMessage, GmailThread } from "./gmail-api.js"
import {
  type Attachment,
  attachmentsOf,
  decodeEntities,
  plainTextBody,
  truncatedBody,
  withoutQuotedHistory
} from "./gmail-body.js"

export interface MessageHeaders {
  [key: string]: unknown
  id: string
  threadId: string
  date: string
  from: string
  to: string
  cc?: string
  subject: string
  labels: Array<string>
}

export interface MessageSummary extends MessageHeaders {
  snippet: string
}

export interface MessageDetail extends MessageHeaders {
  replyTo?: string
  body: string
  attachments?: Array<Attachment>
}

export interface ThreadSummary {
  [key: string]: unknown
  id: string
  subject: string
  from: Array<string>
  messages: number
  date: string
  snippet: string
  labels: Array<string>
}

export type BodyStyle = "whole" | "latest"

export const headerOf = (message: GmailMessage, name: string): string =>
  message.payload.headers?.find((header) => header.name.toLowerCase() === name.toLowerCase())
    ?.value ?? ""

export const senderOf = (message: GmailMessage): MailAddress =>
  parseAddresses(headerOf(message, "From"))[0] ?? { email: "", name: "" }

export const receivedAt = (message: GmailMessage): string =>
  new Date(Number(message.internalDate)).toISOString()

export const messageSummary = (message: GmailMessage): MessageSummary => ({
  ...messageHeaders(message),
  snippet: decodeEntities(message.snippet)
})

export const messageDetail = (message: GmailMessage, style: BodyStyle): MessageDetail => {
  const attachments = attachmentsOf(message.payload)
  return {
    ...messageHeaders(message),
    ...presentHeader("replyTo", headerOf(message, "Reply-To")),
    body: truncatedBody(bodyText(message, style)),
    ...(attachments.length === 0 ? {} : { attachments })
  }
}

export const threadSummary = (thread: GmailThread): ThreadSummary => {
  const first = thread.messages[0]
  const last = thread.messages.at(-1)
  return {
    id: thread.id,
    subject: first === undefined ? "" : headerOf(first, "Subject"),
    from: senderNames(thread.messages),
    messages: thread.messages.length,
    date: last === undefined ? "" : receivedAt(last),
    snippet: last === undefined ? "" : decodeEntities(last.snippet),
    labels: [...new Set(thread.messages.flatMap((message) => message.labelIds))]
  }
}

const messageHeaders = (message: GmailMessage): MessageHeaders => ({
  id: message.id,
  threadId: message.threadId,
  date: receivedAt(message),
  from: headerOf(message, "From"),
  to: headerOf(message, "To"),
  ...presentHeader("cc", headerOf(message, "Cc")),
  subject: headerOf(message, "Subject"),
  labels: message.labelIds
})

const presentHeader = (key: string, value: string): Record<string, string> =>
  value === "" ? {} : { [key]: value }

const bodyText = (message: GmailMessage, style: BodyStyle): string => {
  const body = plainTextBody(message.payload)
  if (style === "whole") return body

  return withoutQuotedHistory(body)
}

const senderNames = (messages: ReadonlyArray<GmailMessage>): Array<string> => [
  ...new Set(messages.map(senderOf).map((sender) => sender.name || sender.email))
]
