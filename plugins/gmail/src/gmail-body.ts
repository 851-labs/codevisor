import type { GmailPart } from "./gmail-api.js"

export interface Attachment {
  filename: string
  mimeType: string
  size: number
}

export const maxBodyChars = 20_000

export const plainTextBody = (payload: GmailPart): string => {
  const plain = bodyData(payload, "text/plain")
  if (plain !== undefined) return normalizedLines(decodeBase64Url(plain))

  const html = bodyData(payload, "text/html")
  if (html !== undefined) return htmlToText(decodeBase64Url(html))

  return ""
}

export const attachmentsOf = (payload: GmailPart): Array<Attachment> =>
  allParts(payload)
    .filter((part) => (part.filename ?? "") !== "")
    .map((part) => ({
      filename: String(part.filename),
      mimeType: part.mimeType ?? "application/octet-stream",
      size: part.body?.size ?? 0
    }))

export const withoutQuotedHistory = (body: string): string => {
  const lines = body.split("\n")
  const start = quotedHistoryStart(lines)
  if (start === undefined) return body

  return `${lines.slice(0, start).join("\n").trimEnd()}\n[quoted history hidden]`
}

export const truncatedBody = (body: string): string => {
  if (body.length <= maxBodyChars) return body

  return `${body.slice(0, maxBodyChars)}\n[truncated: ${body.length - maxBodyChars} more characters]`
}

export const decodeEntities = (text: string): string =>
  Object.entries(namedEntities).reduce(
    (decoded, [name, character]) => decoded.replaceAll(`&${name};`, character),
    text
      .replace(/&#(\d+);/g, (entity, code: string) => codePoint(Number(code), entity))
      .replace(/&#x([\da-f]+);/gi, (entity, code: string) =>
        codePoint(Number.parseInt(code, 16), entity)
      )
  )

const allParts = (part: GmailPart): Array<GmailPart> => [
  part,
  ...(part.parts ?? []).flatMap(allParts)
]

const bodyData = (payload: GmailPart, mimeType: string): string | undefined =>
  allParts(payload).find((part) => isInlineBody(part, mimeType))?.body?.data

const isInlineBody = (part: GmailPart, mimeType: string): boolean =>
  part.mimeType === mimeType && part.body?.data !== undefined && (part.filename ?? "") === ""

const decodeBase64Url = (data: string): string => Buffer.from(data, "base64url").toString("utf8")

const normalizedLines = (text: string): string =>
  text
    .replaceAll("\r\n", "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim()

const htmlToText = (html: string): string =>
  normalizedLines(
    decodeEntities(
      html
        .replace(/<(style|script|head)[^>]*>[\s\S]*?<\/\1>/gi, "")
        .replace(/<br\s*\/?>|<\/(p|div|li|tr|h[1-6]|blockquote)>/gi, "\n")
        .replace(/<[^>]+>/g, "")
    )
      .replace(/[ \t]+\n/g, "\n")
      .replace(/ /g, " ")
  )

const codePoint = (code: number, entity: string): string => {
  if (code > maxCodePoint) return entity

  return String.fromCodePoint(code)
}

const maxCodePoint = 0x10ffff

const namedEntities: Readonly<Record<string, string>> = {
  nbsp: " ",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  amp: "&"
}

const quotedLine = /^\s*>/

const quotedHistoryStart = (lines: ReadonlyArray<string>): number | undefined => {
  const attribution = lines.findIndex(
    (line, index) => line.trim().endsWith("wrote:") && onlyQuotesAfter(lines, index + 1)
  )
  if (attribution === -1) return undefined

  const start = attributionStart(lines, attribution)
  return start === 0 ? undefined : start
}

const onlyQuotesAfter = (lines: ReadonlyArray<string>, index: number): boolean => {
  const rest = lines.slice(index).filter((line) => line.trim() !== "")
  return rest.length > 0 && rest.every((line) => quotedLine.test(line))
}

const attributionStart = (lines: ReadonlyArray<string>, index: number): number => {
  if (startsAttribution(lines[index])) return index
  if (startsAttribution(lines[index - 1])) return index - 1

  return index
}

const startsAttribution = (line: string | undefined): boolean =>
  line?.trim().startsWith("On ") === true
