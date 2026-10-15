import { createHash } from "node:crypto"
import { mkdir, readFile, rename, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { Schema } from "effect"

import type { AppIconLoader } from "./tool-icon-apps.js"
import {
  isPublicHost,
  pageIconCandidates,
  publicFaviconUrl,
  rankMcpIcons
} from "./tool-icon-candidates.js"
import { normalizeIcon, type ToolIconAsset } from "./tool-icon-images.js"

export {
  isInertSvg,
  normalizeIcon,
  sniffImageFormat,
  type ToolIconAsset
} from "./tool-icon-images.js"

export interface McpIcon {
  readonly src: string
  readonly mimeType?: string | undefined
  readonly sizes?: ReadonlyArray<string> | undefined
  readonly theme?: string | undefined
}

export interface McpIconSources {
  readonly url?: string | undefined
  readonly icons?: ReadonlyArray<McpIcon> | undefined
  readonly websiteUrl?: string | undefined
}

export type ToolIconTheme = "light" | "dark"

export interface ToolIconStore {
  readonly site: (origin: string, theme: ToolIconTheme) => Promise<ToolIconAsset | undefined>
  readonly mcp: (
    serverId: string,
    host: string | undefined,
    theme: ToolIconTheme
  ) => Promise<ToolIconAsset | undefined>
  readonly app: (bundleId: string, path: string | undefined) => Promise<ToolIconAsset | undefined>
}

export interface ToolIconStoreOptions {
  readonly dir: string
  readonly mcpSources?: (serverId: string) => Promise<McpIconSources | undefined>
  readonly fetchImpl?: typeof fetch
  readonly appIcon?: AppIconLoader
  readonly now?: () => number
  readonly background?: (refresh: Promise<unknown>) => void
}

export const TOOL_ICON_MAX_BYTES = 512 * 1024
const HTML_MAX_BYTES = 2 * 1024 * 1024
const FETCH_TIMEOUT_MS = 5_000
const HIT_TTL_MS = 7 * 24 * 60 * 60 * 1000
const MISS_TTL_MS = 6 * 60 * 60 * 1000

const BRAND_SITES: Readonly<Record<string, string>> = {
  "mcp.sentry.dev": "https://sentry.io",
  "api.githubcopilot.com": "https://github.com",
  "mcp.notion.com": "https://www.notion.so"
}

export { pageIconCandidates } from "./tool-icon-candidates.js"

const hostOf = (url: string): string | undefined => {
  try {
    return new URL(url).hostname
  } catch {
    return undefined
  }
}

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

const CacheRecord = Schema.Struct({
  key: Schema.String,
  fetchedAt: Schema.Number,
  contentType: Schema.optionalKey(Schema.Literals(["image/png", "image/x-icon"])),
  source: Schema.optionalKey(Schema.Literals(["serverInfo", "favicon"])),
  triedServerInfo: Schema.optionalKey(Schema.Boolean)
})
type CacheRecord = typeof CacheRecord.Type

interface Resolved {
  readonly asset: ToolIconAsset | undefined
  readonly source?: CacheRecord["source"]
  readonly triedServerInfo?: boolean
}

export const makeToolIconStore = (options: ToolIconStoreOptions): ToolIconStore => {
  const now = options.now ?? Date.now
  /* v8 ignore start */
  const fetchImpl = options.fetchImpl ?? globalThis.fetch
  const background =
    options.background ?? ((refresh: Promise<unknown>) => void refresh.catch(() => undefined))
  /* v8 ignore stop */
  const inFlight = new Map<string, Promise<ToolIconAsset | undefined>>()

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
        tail = (tail + decoder.decode(value, { stream: true })).slice(-4096)
        if (/<\/head\s*>|<body[\s>]/i.test(tail)) break
      }
      await reader.cancel()
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
      } catch {}
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
      const record = Schema.decodeUnknownSync(CacheRecord)(
        JSON.parse(await readFile(files.record, "utf8"))
      )
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
    } catch {}
  }

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
        (record) =>
          record.source !== "serverInfo" &&
          record.triedServerInfo !== true &&
          (sources?.icons?.length ?? 0) > 0
      )
    }
  }
}
