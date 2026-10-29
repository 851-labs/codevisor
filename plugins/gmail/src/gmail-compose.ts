import { formatAddress, parseAddresses, type MailAddress } from "./gmail-addresses.js"
import type { Outgoing } from "./gmail-api.js"

export interface MessageFields {
  to: string
  cc: string
  bcc: string
  subject: string
  body: string
  inReplyTo: string
  references: string
  threadId: string | undefined
}

export const composeMessage = (fields: MessageFields): Outgoing => ({
  raw: encodeRaw(messageHeaders(fields), fields.body),
  threadId: fields.threadId
})

const messageHeaders = (fields: MessageFields): Array<[string, string]> => [
  ...optionalHeader("To", addressHeader(fields.to)),
  ...optionalHeader("Cc", addressHeader(fields.cc)),
  ...optionalHeader("Bcc", addressHeader(fields.bcc)),
  ["Subject", encodedWord(singleLine(fields.subject))],
  ...optionalHeader("In-Reply-To", singleLine(fields.inReplyTo)),
  ...optionalHeader("References", singleLine(fields.references)),
  ["MIME-Version", "1.0"],
  ["Content-Type", 'text/plain; charset="UTF-8"'],
  ["Content-Transfer-Encoding", "base64"]
]

const optionalHeader = (name: string, value: string): Array<[string, string]> => {
  if (value === "") return []

  return [[name, value]]
}

const addressHeader = (value: string): string =>
  parseAddresses(singleLine(value)).map(encodedAddress).join(", ")

const encodedAddress = (address: MailAddress): string => {
  if (printableAscii.test(address.name)) return formatAddress(address)

  return `${encodedWord(address.name)} <${address.email}>`
}

const encodedWord = (value: string): string => {
  if (printableAscii.test(value)) return value

  return `=?UTF-8?B?${Buffer.from(value, "utf8").toString("base64")}?=`
}

const encodeRaw = (headers: ReadonlyArray<[string, string]>, body: string): string => {
  const head = headers.map(([name, value]) => `${name}: ${value}`).join(crlf)
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
const printableAscii = /^[ -~]*$/
const lineBreaks = /[\r\n]+/g
const base64LineLength = 76
