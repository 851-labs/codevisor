import type { GmailApi, GmailMessage } from "./gmail-api.js"
import { headerOf } from "./gmail-message.js"

export interface Composition {
  to?: string | undefined
  cc?: string | undefined
  subject?: string | undefined
  body: string
  threadId?: string | undefined
  inReplyToMessageId?: string | undefined
}

export interface OutgoingMessage {
  raw: string
  threadId: string | undefined
}

export const composeMessage = async (
  api: GmailApi,
  composition: Composition
): Promise<OutgoingMessage> => {
  let reply: ReplyContext | undefined
  if (composition.inReplyToMessageId !== undefined) {
    reply = replyContext(await api.message(composition.inReplyToMessageId, "metadata"))
  }

  return {
    raw: encodeRaw(messageHeaders(composition, reply), composition.body),
    threadId: composition.threadId ?? reply?.threadId
  }
}

interface ReplyContext {
  threadId: string
  from: string
  subject: string
  messageId: string
  references: string
}

const replyContext = (original: GmailMessage): ReplyContext => ({
  threadId: original.threadId,
  from: headerOf(original, "From"),
  subject: headerOf(original, "Subject"),
  messageId: headerOf(original, "Message-ID"),
  references: headerOf(original, "References")
})

const messageHeaders = (
  composition: Composition,
  reply: ReplyContext | undefined
): Array<[string, string]> => [
  ...optionalHeader("To", composition.to ?? reply?.from),
  ...optionalHeader("Cc", composition.cc),
  ["Subject", encodedWord(composition.subject ?? replySubject(reply))],
  ...replyHeaders(reply),
  ["MIME-Version", "1.0"],
  ["Content-Type", 'text/plain; charset="UTF-8"'],
  ["Content-Transfer-Encoding", "base64"]
]

const optionalHeader = (name: string, value: string | undefined): Array<[string, string]> => {
  if (value === undefined || value.trim() === "") return []

  return [[name, value]]
}

const replySubject = (reply: ReplyContext | undefined): string => {
  if (reply === undefined) return ""
  if (replyPrefix.test(reply.subject)) return reply.subject

  return `Re: ${reply.subject}`
}

const replyHeaders = (reply: ReplyContext | undefined): Array<[string, string]> => {
  if (reply === undefined || reply.messageId === "") return []

  const references = [reply.references, reply.messageId].filter((value) => value !== "").join(" ")
  return [
    ["In-Reply-To", reply.messageId],
    ["References", references]
  ]
}

const encodedWord = (value: string): string => {
  if (printableAscii.test(value)) return value

  return `=?UTF-8?B?${Buffer.from(value, "utf8").toString("base64")}?=`
}

const encodeRaw = (headers: ReadonlyArray<[string, string]>, body: string): string => {
  const head = headers.map(([name, value]) => `${name}: ${singleLine(value)}`).join(crlf)
  const message = `${head}${crlf}${crlf}${wrappedBase64(body)}${crlf}`
  return Buffer.from(message, "utf8").toString("base64url")
}

const singleLine = (value: string): string => value.replace(lineBreaks, " ").trim()

const wrappedBase64 = (body: string): string => {
  const encoded = Buffer.from(body, "utf8").toString("base64")
  const lineCount = Math.ceil(encoded.length / base64LineLength)
  return Array.from({ length: lineCount }, (_, line) =>
    encoded.slice(line * base64LineLength, (line + 1) * base64LineLength)
  ).join(crlf)
}

const crlf = "\r\n"
const replyPrefix = /^re:/i
const printableAscii = /^[ -~]*$/
const lineBreaks = /[\r\n]+/g
const base64LineLength = 76
