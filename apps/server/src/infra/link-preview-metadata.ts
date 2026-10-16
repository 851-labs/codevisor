import { htmlAttribute } from "./tool-icon-candidates.js"

export interface LinkPreviewMetadata {
  readonly title?: string
  readonly description?: string
  readonly siteName?: string
  readonly imageUrl?: string
  readonly refreshUrl?: string
}

const NAMED_ENTITIES: Readonly<Record<string, string>> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " "
}

export const decodeEntities = (text: string): string =>
  text.replace(/&(#x[\da-f]+|#\d+|[a-z]+);/gi, (entity, body: string) => {
    if (body.startsWith("#")) {
      const code =
        body[1] === "x" || body[1] === "X" ? parseInt(body.slice(2), 16) : Number(body.slice(1))
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity
    }
    return NAMED_ENTITIES[body.toLowerCase()] ?? entity
  })

const clean = (text: string | undefined): string | undefined => {
  if (text === undefined) return undefined
  const value = decodeEntities(decodeEntities(text)).replace(/\s+/g, " ").trim()
  return value === "" ? undefined : value
}

const absoluteUrl = (href: string | undefined, pageUrl: string): string | undefined => {
  if (href === undefined) return undefined
  try {
    const url = new URL(decodeEntities(href.trim()), pageUrl)
    return url.protocol === "https:" || url.protocol === "http:" ? url.toString() : undefined
  } catch {
    return undefined
  }
}

export const parseLinkPreviewMetadata = (html: string, pageUrl: string): LinkPreviewMetadata => {
  const meta = new Map<string, string>()
  for (const match of html.matchAll(/<meta\b[^>]*>/gi)) {
    const key = ["property", "name", "http-equiv"]
      .map((name) => htmlAttribute(match[0], name))
      .find((value) => value !== undefined)
      ?.toLowerCase()
    const content = htmlAttribute(match[0], "content")
    if (key !== undefined && content !== undefined && !meta.has(key)) meta.set(key, content)
  }
  const first = (...keys: ReadonlyArray<string>): string | undefined =>
    keys.map((key) => clean(meta.get(key))).find((value) => value !== undefined)
  const title =
    first("og:title", "twitter:title") ?? clean(/<title\b[^>]*>([^<]*)/i.exec(html)?.[1])
  const description = first("og:description", "twitter:description", "description")
  const siteName = first("og:site_name", "application-name")
  const imageUrl = [
    "og:image:secure_url",
    "og:image",
    "og:image:url",
    "twitter:image",
    "twitter:image:src"
  ]
    .map((key) => absoluteUrl(meta.get(key), pageUrl))
    .find((url) => url !== undefined)
  const refreshUrl = absoluteUrl(
    /url\s*=\s*['"]?([^'"]+)/i.exec(meta.get("refresh") ?? "")?.[1],
    pageUrl
  )
  return {
    ...(title === undefined ? {} : { title }),
    ...(description === undefined ? {} : { description }),
    ...(siteName === undefined ? {} : { siteName }),
    ...(imageUrl === undefined ? {} : { imageUrl }),
    ...(refreshUrl === undefined ? {} : { refreshUrl })
  }
}
