import { createHash } from "node:crypto"
import { mkdir, readFile, rename, writeFile } from "node:fs/promises"
import { join } from "node:path"

import type { AppIconLoader } from "./tool-icon-apps.js"
import {
  isPublicHost,
  pageIconCandidates,
  publicFaviconUrl,
  rankMcpIcons
} from "./tool-icon-candidates.js"
import { normalizeIcon, type ToolIconAsset } from "./tool-icon-images.js"

/// Artwork for what a gateway workflow touched: the favicon of a site a
/// browser call visited, or an MCP server's own icon. Resolved once on this
/// machine and kept on disk, so a reopened chat draws its icons from cache.
/// Every fetch is credential-free and every image is treated as untrusted.

export {
  isInertSvg,
  normalizeIcon,
  sniffImageFormat,
  type ToolIconAsset
} from "./tool-icon-images.js"

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
  /// An app Computer Use drove, by bundle ID; `path` is where it was
  /// installed when it ran. Undefined off macOS or when it isn't here.
  readonly app: (bundleId: string, path: string | undefined) => Promise<ToolIconAsset | undefined>
}

export interface ToolIconStoreOptions {
  readonly dir: string
  readonly mcpSources?: (serverId: string) => Promise<McpIconSources | undefined>
  readonly fetchImpl?: typeof fetch
  /// Reads an installed app's icon (macOS); absent elsewhere.
  readonly appIcon?: AppIconLoader
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

/// Where an MCP host's brand lives when it isn't the host's own domain.
const BRAND_SITES: Readonly<Record<string, string>> = {
  "mcp.sentry.dev": "https://sentry.io",
  "api.githubcopilot.com": "https://github.com",
  "mcp.notion.com": "https://www.notion.so"
}

/// The icon links a page declares, best first: icons for the appearance,
/// then sized raster icons nearest above 64px, then SVGs, then smaller
/// rasters, then unsized icons, then touch icons (opaque squares that read
/// heavier at row size). Monochrome mask icons are skipped.
export { pageIconCandidates } from "./tool-icon-candidates.js"

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
        asset:
          (await favicon(parsed.origin, theme)) ??
          (isPublicHost(parsed.hostname)
            ? await imageAt(publicFaviconUrl(parsed.hostname))
            : undefined),
        source: "favicon"
      }))
    },
    app: async (bundleId, path) => {
      const loadIcon = options.appIcon
      if (loadIcon === undefined) return undefined
      // An app's icon doesn't change with the appearance.
      return cached(`app:${bundleId}`, async () => {
        const data = await loadIcon(bundleId, path)
        return { asset: data === undefined ? undefined : await normalizeIcon(data) }
      })
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
