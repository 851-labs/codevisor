import type { GmailMessage, GmailPart } from "./gmail-api.js"

export interface MailAddress {
  email: string
  name: string
}

export interface MessageSummary {
  [key: string]: unknown
  id: string
  threadId: string
  from: MailAddress
  to: Array<string>
  cc: Array<string>
  subject: string
  date: string
  snippet: string
  labels: Array<string>
  receivedAt: string
}

export interface MessageDetail extends MessageSummary {
  messageIdHeader: string
  body: string
}

export const maxBodyChars = 50_000

export const headerOf = (message: GmailMessage, name: string): string =>
  message.payload.headers?.find((header) => header.name.toLowerCase() === name.toLowerCase())
    ?.value ?? ""

export const parseAddresses = (value: string): Array<MailAddress> =>
  (value.match(addressPattern) ?? [])
    .map((part) => part.trim())
    .filter((part) => part !== "")
    .map(parseAddress)

export const messageSummary = (message: GmailMessage): MessageSummary => ({
  id: message.id,
  threadId: message.threadId,
  from: parseAddresses(headerOf(message, "From"))[0] ?? { email: "", name: "" },
  to: emailsIn(headerOf(message, "To")),
  cc: emailsIn(headerOf(message, "Cc")),
  subject: headerOf(message, "Subject"),
  date: headerOf(message, "Date"),
  snippet: message.snippet,
  labels: message.labelIds,
  receivedAt: new Date(Number(message.internalDate)).toISOString()
})

export const messageDetail = (message: GmailMessage): MessageDetail => ({
  ...messageSummary(message),
  messageIdHeader: headerOf(message, "Message-ID"),
  body: truncated(plainTextBody(message.payload))
})

export const plainTextBody = (payload: GmailPart): string => {
  const plain = bodyData(payload, "text/plain")
  if (plain !== undefined) return decodeBase64Url(plain)

  const html = bodyData(payload, "text/html")
  if (html !== undefined) return htmlToText(decodeBase64Url(html))

  return ""
}

const addressPattern = /(?:"[^"]*"|<[^>]*>|[^,])+/g
const angleAddress = /^(.*?)\s*<([^>]*)>$/

const parseAddress = (part: string): MailAddress => {
  const match = angleAddress.exec(part)
  if (match === null) return { email: part.toLowerCase(), name: "" }

  return {
    email: String(match[2]).trim().toLowerCase(),
    name: String(match[1]).replaceAll('"', "").trim()
  }
}

const emailsIn = (value: string): Array<string> =>
  parseAddresses(value).map((address) => address.email)

const allParts = (part: GmailPart): Array<GmailPart> => [
  part,
  ...(part.parts ?? []).flatMap(allParts)
]

const bodyData = (payload: GmailPart, mimeType: string): string | undefined =>
  allParts(payload).find((part) => part.mimeType === mimeType && part.body?.data !== undefined)
    ?.body?.data

const decodeBase64Url = (data: string): string => Buffer.from(data, "base64url").toString("utf8")

const htmlToText = (html: string): string =>
  html
    .replace(/<(style|script)[^>]*>[\s\S]*?<\/\1>/gi, "")
    .replace(/<br\s*\/?>|<\/(p|div|li|tr|h[1-6])>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replaceAll("&nbsp;", " ")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&amp;", "&")
    .replace(/\n{3,}/g, "\n\n")
    .trim()

const truncated = (body: string): string => {
  if (body.length <= maxBodyChars) return body

  return `${body.slice(0, maxBodyChars)}\n…[truncated]`
}
