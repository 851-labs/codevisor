import { createHash } from "node:crypto"
import { mkdir, readFile, rename, writeFile } from "node:fs/promises"
import { join } from "node:path"

import sharp from "sharp"

/// Artwork for what a gateway workflow touched: the favicon of a site a
/// browser call visited, or an MCP server's own icon. Resolved once on this
/// machine and kept on disk, so a reopened chat draws its icons from cache.
/// Every fetch is credential-free and every image is treated as untrusted.

export interface ToolIconAsset {
  readonly contentType: "image/png" | "image/x-icon"
  readonly data: Uint8Array
}

/// An MCP icon as the protocol defines it (`Implementation.icons`).
export interface McpIcon {
  readonly src: string
  readonly mimeType?: string | undefined
  readonly sizes?: ReadonlyArray<string> | undefined
  readonly theme?: string | undefined
}

/// What this machine knows about an MCP server's artwork: its URL, and the
/// `serverInfo` its live connection reported.
export interface McpIconSources {
  readonly url?: string | undefined
  readonly icons?: ReadonlyArray<McpIcon> | undefined
  readonly websiteUrl?: string | undefined
}

/// The appearance the icon is drawn on; sites and MCP servers may ship a
/// variant for each.
export type ToolIconTheme = "light" | "dark"

export interface ToolIconStore {
  /// The favicon of `origin` (scheme://host[:port]); undefined when none.
  readonly site: (origin: string, theme: ToolIconTheme) => Promise<ToolIconAsset | undefined>
  /// An MCP server's icon: its own `serverInfo.icons`, else its brand's
  /// favicon. `host` covers servers this machine doesn't know.
  readonly mcp: (
    serverId: string,
    host: string | undefined,
    theme: ToolIconTheme
  ) => Promise<ToolIconAsset | undefined>
}

export interface ToolIconStoreOptions {
  readonly dir: string
  readonly mcpSources?: (serverId: string) => Promise<McpIconSources | undefined>
  readonly fetchImpl?: typeof fetch
  readonly now?: () => number
  /// Runs a refresh that nothing awaits (a stale icon was already served).
  readonly background?: (refresh: Promise<unknown>) => void
}

export const TOOL_ICON_MAX_BYTES = 512 * 1024
/// Some heads inline hundreds of kilobytes of CSS before their icon links.
const HTML_MAX_BYTES = 2 * 1024 * 1024
const FETCH_TIMEOUT_MS = 5_000
const HIT_TTL_MS = 7 * 24 * 60 * 60 * 1000
const MISS_TTL_MS = 6 * 60 * 60 * 1000
const ICON_PIXELS = 128

/// Where an MCP host's brand lives when it isn't the host's own domain.
const BRAND_SITES: Readonly<Record<string, string>> = {
  "mcp.sentry.dev": "https://sentry.io",
  "api.githubcopilot.com": "https://github.com",
  "mcp.notion.com": "https://www.notion.so"
}

type ImageFormat = "png" | "jpeg" | "gif" | "webp" | "ico" | "svg"

const startsWith = (data: Uint8Array, bytes: ReadonlyArray<number>, offset = 0): boolean =>
  data.length >= offset + bytes.length &&
  bytes.every((byte, index) => data[offset + index] === byte)

/// The image format by magic bytes. Declared MIME types are advisory only.
export const sniffImageFormat = (data: Uint8Array): ImageFormat | undefined => {
  if (startsWith(data, [0x89, 0x50, 0x4e, 0x47])) return "png"
  if (startsWith(data, [0xff, 0xd8, 0xff])) return "jpeg"
  if (startsWith(data, [0x47, 0x49, 0x46, 0x38])) return "gif"
  if (startsWith(data, [0x52, 0x49, 0x46, 0x46]) && startsWith(data, [0x57, 0x45, 0x42, 0x50], 8))
    return "webp"
  if (startsWith(data, [0x00, 0x00, 0x01, 0x00])) return "ico"
  const head = new TextDecoder().decode(data.subarray(0, 1024)).trimStart()
  if (/^(?:<\?xml[^>]*>\s*)?(?:<!--[\s\S]*?-->\s*)*<svg[\s>]/i.test(head)) return "svg"
  return undefined
}

/// SVGs become rasters here and never render as documents, but they are
/// still refused when they carry active content or reach outside themselves.
export const isInertSvg = (source: string): boolean => {
  if (/<(?:script|foreignObject|iframe|object|embed)\b/i.test(source)) return false
  if (/<!DOCTYPE|<!ENTITY|@import\b/i.test(source)) return false
  for (const match of source.matchAll(/(?:href|xlink:href)\s*=\s*["']([^"']*)["']/gi)) {
    if (!match[1]!.startsWith("#")) return false
  }
  for (const match of source.matchAll(/url\(\s*["']?([^)'"\s]+)["']?\s*\)/gi)) {
    if (!match[1]!.startsWith("#")) return false
  }
  return true
}

/// A bounded PNG for every raster and SVG source. ICO passes through as-is:
/// both clients decode it natively, and sharp does not.
export const normalizeIcon = async (data: Uint8Array): Promise<ToolIconAsset | undefined> => {
  const format = sniffImageFormat(data)
  if (format === undefined) return undefined
  if (format === "ico") return { contentType: "image/x-icon", data }
  if (format === "svg" && !isInertSvg(new TextDecoder().decode(data))) return undefined
  try {
    const png = await sharp(data, {
      density: format === "svg" ? 192 : 72,
      limitInputPixels: 16_777_216,
      animated: false
    })
      .resize({ fit: "inside", width: ICON_PIXELS, height: ICON_PIXELS, withoutEnlargement: true })
      .png({ compressionLevel: 9 })
      .toBuffer()
    return { contentType: "image/png", data: new Uint8Array(png) }
  } catch {
    return undefined
  }
}

const attribute = (tag: string, name: string): string | undefined => {
  const match = new RegExp(`\\s${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(tag)
  return match === null ? undefined : (match[1] ?? match[2] ?? match[3])
}

const largestSize = (sizes: string | undefined): number | undefined => {
  if (sizes === undefined) return undefined
  if (/\bany\b/i.test(sizes)) return Number.POSITIVE_INFINITY
  const dimensions = [...sizes.matchAll(/(\d+)x(\d+)/gi)].map((match) => Number(match[1]))
  return dimensions.length === 0 ? undefined : Math.max(...dimensions)
}

/// How well a declared color scheme fits the appearance: icons made for it
/// first, icons made for the other one last.
const themeRank = (declared: ToolIconTheme | undefined, theme: ToolIconTheme): number =>
  declared === undefined ? 0 : declared === theme ? -5000 : 5000

/// The icon links a page declares, best first: icons for the appearance,
/// then sized raster icons nearest above 64px, then SVGs, then smaller
/// rasters, then unsized icons, then touch icons (opaque squares that read
/// heavier at row size). Monochrome mask icons are skipped.
export const pageIconCandidates = (
  html: string,
  pageUrl: string,
  theme: ToolIconTheme = "light"
): ReadonlyArray<string> => {
  const ranked: Array<{ readonly url: string; readonly rank: number; readonly order: number }> = []
  for (const match of html.matchAll(/<link\b[^>]*>/gi)) {
    const tag = match[0]
    const rel = attribute(tag, "rel")?.toLowerCase().split(/\s+/) ?? []
    const href = attribute(tag, "href")
    if (href === undefined || rel.includes("mask-icon")) continue
    const touch = rel.includes("apple-touch-icon") || rel.includes("apple-touch-icon-precomposed")
    if (!touch && !rel.includes("icon")) continue
    let url: URL
    try {
      url = new URL(href.replaceAll("&amp;", "&"), pageUrl)
    } catch {
      continue
    }
    if (url.protocol !== "https:" && url.protocol !== "http:" && url.protocol !== "data:") continue
    const type = attribute(tag, "type")?.toLowerCase()
    const svg = type === "image/svg+xml" || /\.svg(?:$|\?)/i.test(url.pathname)
    const size = largestSize(attribute(tag, "sizes"))
    const rank = touch
      ? 3000
      : svg || size === Number.POSITIVE_INFINITY
        ? 50
        : size === undefined
          ? 2000
          : size >= 64
            ? size - 64
            : 100 + (64 - size)
    const media = attribute(tag, "media")?.toLowerCase() ?? ""
    const scheme = /prefers-color-scheme\s*:\s*dark/.test(media)
      ? "dark"
      : /prefers-color-scheme\s*:\s*light/.test(media)
        ? "light"
        : undefined
    ranked.push({
      url: url.toString(),
      rank: rank + themeRank(scheme, theme),
      order: ranked.length
    })
  }
  ranked.sort((lhs, rhs) => lhs.rank - rhs.rank || lhs.order - rhs.order)
  return [...new Set(ranked.map((candidate) => candidate.url))]
}

const hostOf = (url: string): string | undefined => {
  try {
    return new URL(url).hostname
  } catch {
    return undefined
  }
}

/// The registrable part of a host (`mcp.linear.app` → `linear.app`), with
/// the common two-label public suffixes (`example.co.uk`) kept whole.
export const registrableDomain = (host: string): string => {
  const labels = host.toLowerCase().split(".").filter(Boolean)
  if (labels.length <= 2 || /^\d+$/.test(labels.at(-1)!)) return labels.join(".")
  const secondLevel = labels.at(-2)!
  const keep =
    labels.at(-1)!.length === 2 && ["co", "com", "net", "org", "ac", "gov"].includes(secondLevel)
      ? 3
      : 2
  return labels.slice(-keep).join(".")
}

/// The MCP protocol asks clients to take icons only from HTTPS or `data:`
/// URIs, and from the server's own origin. A server's own brand domain
/// (`linear.app` for `mcp.linear.app`) counts as its origin here.
export const allowedMcpIconUrl = (src: string, serverUrl: string | undefined): boolean => {
  let url: URL
  try {
    url = new URL(src)
  } catch {
    return false
  }
  if (url.protocol === "data:") return true
  const serverHost = serverUrl === undefined ? undefined : hostOf(serverUrl)
  if (url.protocol !== "https:" || serverHost === undefined) return false
  return registrableDomain(url.hostname) === registrableDomain(serverHost)
}

/// Best first: icons for the appearance's background (MCP's `theme`), then
/// theme-free ones, nearest 64px, SVGs as large.
const rankMcpIcons = (
  icons: ReadonlyArray<McpIcon>,
  theme: ToolIconTheme
): ReadonlyArray<McpIcon> =>
  icons
    .map((icon, order) => {
      const sizes = largestSize(icon.sizes?.join(" "))
      const size = sizes === Number.POSITIVE_INFINITY ? 64 : (sizes ?? 48)
      const declared = icon.theme === "dark" || icon.theme === "light" ? icon.theme : undefined
      return { icon, order, rank: themeRank(declared, theme) + Math.abs(size - 64) }
    })
    .toSorted((lhs, rhs) => lhs.rank - rhs.rank || lhs.order - rhs.order)
    .map(({ icon }) => icon)

const decodeDataUri = (src: string): Uint8Array | undefined => {
  const match = /^data:([^,]*?)(;base64)?,(.*)$/is.exec(src)
  if (match === null) return undefined
  try {
    const data =
      match[2] === undefined
        ? new TextEncoder().encode(decodeURIComponent(match[3]!))
        : new Uint8Array(Buffer.from(match[3]!, "base64"))
    return data.byteLength > TOOL_ICON_MAX_BYTES ? undefined : data
  } catch {
    return undefined
  }
}

interface CacheRecord {
  readonly key: string
  readonly fetchedAt: number
  readonly contentType?: ToolIconAsset["contentType"]
  /// Where the image came from, so a server that later reports its own
  /// icons replaces a favicon stand-in.
  readonly source?: "serverInfo" | "favicon"
  /// The server's own icons were tried (and none was usable).
  readonly triedServerInfo?: boolean
}

interface Resolved {
  readonly asset: ToolIconAsset | undefined
  readonly source?: CacheRecord["source"]
  readonly triedServerInfo?: boolean
}

export const makeToolIconStore = (options: ToolIconStoreOptions): ToolIconStore => {
  const now = options.now ?? Date.now
  /* v8 ignore start -- production defaults; tests inject a fetch and await refreshes. */
  const fetchImpl = options.fetchImpl ?? globalThis.fetch
  const background =
    options.background ?? ((refresh: Promise<unknown>) => void refresh.catch(() => undefined))
  /* v8 ignore stop */
  const inFlight = new Map<string, Promise<ToolIconAsset | undefined>>()

  /// A credential-free GET with a deadline and a byte ceiling. Redirects may
  /// only land on HTTP(S).
  const fetchBounded = async (
    url: string,
    limit: number,
    accept: string
  ): Promise<{ readonly data: Uint8Array; readonly url: string } | undefined> => {
    try {
      const response = await fetchImpl(url, {
        credentials: "omit",
        headers: { accept },
        redirect: "follow",
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS)
      })
      const finalUrl = response.url === "" ? url : response.url
      if (!response.ok || !/^https?:/i.test(finalUrl)) {
        await response.body?.cancel()
        return undefined
      }
      const reader = response.body?.getReader()
      if (reader === undefined) return undefined
      const chunks: Array<Uint8Array> = []
      let size = 0
      const page = !accept.startsWith("image")
      const decoder = new TextDecoder()
      let tail = ""
      while (size < limit) {
        const { done, value } = await reader.read()
        if (done) break
        chunks.push(value)
        size += value.byteLength
        if (!page) continue
        // Icon links live in the head; stop once it closes.
        tail = (tail + decoder.decode(value, { stream: true })).slice(-4096)
        if (/<\/head\s*>|<body[\s>]/i.test(tail)) break
      }
      await reader.cancel()
      // A page's head is enough to find its icons; an image must be whole.
      if (!page && size >= limit) return undefined
      return { data: new Uint8Array(Buffer.concat(chunks)), url: finalUrl }
    } catch {
      return undefined
    }
  }

  const imageAt = async (url: string): Promise<ToolIconAsset | undefined> => {
    if (url.startsWith("data:")) {
      const data = decodeDataUri(url)
      return data === undefined ? undefined : normalizeIcon(data)
    }
    const fetched = await fetchBounded(url, TOOL_ICON_MAX_BYTES, "image/*")
    return fetched === undefined ? undefined : normalizeIcon(fetched.data)
  }

  /// A site's own declared icons, then `/favicon.ico`.
  const favicon = async (
    origin: string,
    theme: ToolIconTheme
  ): Promise<ToolIconAsset | undefined> => {
    const page = await fetchBounded(`${origin}/`, HTML_MAX_BYTES, "text/html")
    const declared =
      page === undefined
        ? []
        : pageIconCandidates(new TextDecoder().decode(page.data), page.url, theme)
    const fallbackOrigin = page === undefined ? origin : new URL(page.url).origin
    const candidates = [...declared.slice(0, 3), `${fallbackOrigin}/favicon.ico`]
    for (const candidate of new Set(candidates)) {
      const asset = await imageAt(candidate)
      if (asset !== undefined) return asset
    }
    return undefined
  }

  const resolveMcp = async (
    sources: McpIconSources | undefined,
    host: string | undefined,
    theme: ToolIconTheme
  ): Promise<Resolved> => {
    const serverUrl = sources?.url ?? (host === undefined ? undefined : `https://${host}`)
    for (const icon of rankMcpIcons(sources?.icons ?? [], theme)) {
      if (!allowedMcpIconUrl(icon.src, serverUrl)) continue
      const asset = await imageAt(icon.src)
      if (asset !== undefined) return { asset, source: "serverInfo" }
    }
    const triedServerInfo = (sources?.icons?.length ?? 0) > 0
    const origins: Array<string> = []
    const serverHost = serverUrl === undefined ? undefined : hostOf(serverUrl)
    if (serverHost !== undefined && BRAND_SITES[serverHost] !== undefined)
      origins.push(BRAND_SITES[serverHost])
    if (sources?.websiteUrl !== undefined) {
      try {
        const website = new URL(sources.websiteUrl)
        if (website.protocol === "https:" || website.protocol === "http:")
          origins.push(website.origin)
      } catch {
        // An unusable website URL just isn't a candidate.
      }
    }
    if (serverHost !== undefined) {
      origins.push(`https://${registrableDomain(serverHost)}`)
      origins.push(new URL(serverUrl!).origin)
    }
    for (const origin of new Set(origins)) {
      const asset = await favicon(origin, theme)
      if (asset !== undefined) return { asset, source: "favicon", triedServerInfo }
    }
    return { asset: undefined, triedServerInfo }
  }

  const paths = (key: string): { readonly record: string; readonly image: string } => {
    const name = createHash("sha256").update(key).digest("hex")
    return { record: join(options.dir, `${name}.json`), image: join(options.dir, `${name}.img`) }
  }

  const readCache = async (
    key: string
  ): Promise<{ readonly record: CacheRecord; readonly asset?: ToolIconAsset } | undefined> => {
    const files = paths(key)
    try {
      const record = JSON.parse(await readFile(files.record, "utf8")) as CacheRecord
      if (record.contentType === undefined) return { record }
      const data = new Uint8Array(await readFile(files.image))
      return { record, asset: { contentType: record.contentType, data } }
    } catch {
      return undefined
    }
  }

  const writeCache = async (key: string, resolved: Resolved): Promise<void> => {
    const files = paths(key)
    const record: CacheRecord = {
      key,
      fetchedAt: now(),
      ...(resolved.asset === undefined ? {} : { contentType: resolved.asset.contentType }),
      ...(resolved.source === undefined ? {} : { source: resolved.source }),
      ...(resolved.triedServerInfo === true ? { triedServerInfo: true } : {})
    }
    try {
      await mkdir(options.dir, { recursive: true })
      if (resolved.asset !== undefined) {
        await writeFile(`${files.image}.tmp`, resolved.asset.data)
        await rename(`${files.image}.tmp`, files.image)
      }
      await writeFile(`${files.record}.tmp`, JSON.stringify(record))
      await rename(`${files.record}.tmp`, files.record)
    } catch {
      // Without a cache the next request resolves again; nothing else breaks.
    }
  }

  /// Serves from disk when fresh. A stale image is still served at once
  /// while a refresh runs behind it, so reopened chats never wait.
  const cached = async (
    key: string,
    resolve: () => Promise<Resolved>,
    isOutdated: (record: CacheRecord) => boolean = () => false
  ): Promise<ToolIconAsset | undefined> => {
    const refresh = (): Promise<ToolIconAsset | undefined> => {
      const running = inFlight.get(key)
      if (running !== undefined) return running
      const task = resolve()
        .then(async (resolved) => {
          await writeCache(key, resolved)
          return resolved.asset
        })
        .finally(() => inFlight.delete(key))
      inFlight.set(key, task)
      return task
    }
    const entry = await readCache(key)
    if (entry === undefined) return refresh()
    const age = now() - entry.record.fetchedAt
    const outdated = isOutdated(entry.record)
    if (entry.asset === undefined) return age < MISS_TTL_MS && !outdated ? undefined : refresh()
    if (age >= HIT_TTL_MS || outdated) background(refresh())
    return entry.asset
  }

  return {
    site: async (origin, theme) => {
      let parsed: URL
      try {
        parsed = new URL(origin)
      } catch {
        return undefined
      }
      if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return undefined
      const key = `site:${theme}:${parsed.origin}`
      return cached(key, async () => ({
        asset: await favicon(parsed.origin, theme),
        source: "favicon"
      }))
    },
    mcp: async (serverId, host, theme) => {
      const sources = await options.mcpSources?.(serverId).catch(() => undefined)
      const key = `mcp:${theme}:${serverId}:${sources?.url ?? host ?? ""}`
      return cached(
        key,
        () => resolveMcp(sources, host, theme),
        // A favicon stand-in yields once the live server reports icons.
        (record) =>
          record.source !== "serverInfo" &&
          record.triedServerInfo !== true &&
          (sources?.icons?.length ?? 0) > 0
      )
    }
  }
}
