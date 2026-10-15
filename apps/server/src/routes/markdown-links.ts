import { ATTACHMENT_URL_ORIGIN } from "./assistant-artifacts.js"
import { escaped, markdownCode } from "./markdown-artifacts.js"

export interface MarkdownLink {
  readonly url: string
  readonly title?: string
}

interface FoundLink extends MarkdownLink {
  readonly index: number
}

const inlineLinks =
  /(!?)\[((?:!\[[^\]\n]*\]\([^\s)]*\)|[^\]\n])*)\]\(\s*(?:<([^>\n]+)>|((?:[^\s()]|\([^\s()]*\))+))(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)/g
const embeddedImages = /!\[([^\]\n]*)\]\([^\s)]*\)/g
const autolinks = /<(https?:\/\/[^>\s]+)>/gi
const bareLinks = /\bhttps?:\/\/[^\s<>`"'[\]{}|\\^]+/gi
const wholeURL = /^\s*(https?:\/\/\S+)\s*$/i

export const webURL = (candidate: string): string | undefined => {
  try {
    const url = new URL(candidate)
    return (url.protocol === "http:" || url.protocol === "https:") &&
      !url.href.startsWith(ATTACHMENT_URL_ORIGIN)
      ? url.href
      : undefined
  } catch {
    return undefined
  }
}

const count = (text: string, character: string): number => text.split(character).length - 1

const trimBareURL = (raw: string): string => {
  let url = raw
  for (;;) {
    const trimmed = url.replace(/[.,;:!?*_~]+$/, "")
    const unbalanced = trimmed.endsWith(")") && count(trimmed, ")") > count(trimmed, "(")
    const next = unbalanced ? trimmed.slice(0, -1) : trimmed
    if (next === url) return url
    url = next
  }
}

export const markdownLinks = (source: string): ReadonlyArray<MarkdownLink> => {
  const { mask, inline } = markdownCode(source)
  const claimed = new Uint8Array(source.length)
  const inCode = (start: number, end: number): boolean => mask.slice(start, end).some(Boolean)
  const isClaimed = (start: number, end: number): boolean => claimed.slice(start, end).some(Boolean)
  const found: Array<FoundLink> = []
  const add = (index: number, raw: string, label?: string): void => {
    const url = webURL(raw)
    if (url === undefined) return
    const title = label?.trim()
    found.push({
      index,
      url,
      ...(title === undefined || title === "" || webURL(title) === url ? {} : { title })
    })
  }
  for (const match of source.matchAll(inlineLinks)) {
    const end = match.index + match[0].length
    if (escaped(source, match.index) || inCode(match.index, end)) continue
    claimed.fill(1, match.index, end)
    if (match[1] === "")
      add(match.index, match[3] ?? match[4]!, match[2]!.replace(embeddedImages, "$1"))
  }
  for (const match of source.matchAll(autolinks)) {
    const end = match.index + match[0].length
    if (inCode(match.index, end) || isClaimed(match.index, end)) continue
    claimed.fill(1, match.index, end)
    add(match.index, match[1]!)
  }
  for (const match of source.matchAll(bareLinks)) {
    const url = trimBareURL(match[0])
    const end = match.index + url.length
    if (inCode(match.index, end) || isClaimed(match.index, end)) continue
    add(match.index, url)
  }
  for (const span of inline) {
    const url = wholeURL.exec(span.content)?.[1]
    if (url !== undefined) add(span.start, url)
  }
  const seen = new Set<string>()
  return found
    .toSorted((left, right) => left.index - right.index)
    .filter((link) => !seen.has(link.url) && seen.add(link.url))
    .map(({ index: _index, ...link }) => link)
}
