import type { InstalledPlugin } from "./plugin-store.js"
import { PluginsError } from "./plugins-error.js"

export const MAX_PLUGIN_ICON_BYTES = 512 * 1024

export type PluginIconContentType = "image/png"

export interface PluginIconAsset {
  readonly contentType: PluginIconContentType
  readonly data: Uint8Array
}

interface FetchPluginIconOptions {
  readonly plugin: InstalledPlugin
  readonly paneType?: string | undefined
  readonly ensureRunning: () => Promise<number>
  readonly noteSuccess: () => void
  readonly markUnreachable: () => void
  readonly signedContextHeaders: (
    payload: Readonly<Record<string, unknown>>
  ) => Record<string, string>
  readonly timeoutMs: number
  readonly fetchImpl?: typeof fetch
}

type PluginIconSourceContentType = "image/png" | "image/svg+xml" | "image/webp"

const contentTypes = new Set<PluginIconSourceContentType>([
  "image/png",
  "image/svg+xml",
  "image/webp"
])

const iconPath = (plugin: InstalledPlugin, paneType: string | undefined): string => {
  if (paneType === undefined) {
    if (plugin.manifest.iconPath === undefined) {
      throw new PluginsError("notFound", `Plugin ${plugin.id} has no icon`)
    }
    return plugin.manifest.iconPath
  }
  const pane = plugin.manifest.panes.find((candidate) => candidate.type === paneType)
  if (pane === undefined) {
    throw new PluginsError("notFound", `Plugin ${plugin.id} has no pane type: ${paneType}`)
  }
  const path = pane.iconPath ?? plugin.manifest.iconPath
  if (path === undefined) {
    throw new PluginsError("notFound", `Plugin ${plugin.id} pane ${paneType} has no icon`)
  }
  return path
}

/// SVGs render as images in client-owned chrome, never as documents. Reject
/// active markup and network-capable references before the bytes leave the
/// machine so every current and future client gets the same safe subset.
const validateSvg = (pluginId: string, data: Uint8Array): void => {
  let source: string
  try {
    source = new TextDecoder("utf-8", { fatal: true }).decode(data)
  } catch {
    throw new PluginsError("invalid", `Plugin ${pluginId} icon is not valid UTF-8 SVG`)
  }
  if (!/<svg[\s>]/i.test(source)) {
    throw new PluginsError("invalid", `Plugin ${pluginId} icon is not an SVG document`)
  }
  if (/<(?:script|foreignObject|iframe|object|embed)\b/i.test(source)) {
    throw new PluginsError("invalid", `Plugin ${pluginId} SVG icon contains active content`)
  }
  if (/<!DOCTYPE|<!ENTITY/i.test(source)) {
    throw new PluginsError("invalid", `Plugin ${pluginId} SVG icon contains a document entity`)
  }
  if (/@import\b/i.test(source)) {
    throw new PluginsError("invalid", `Plugin ${pluginId} SVG icon contains an external stylesheet`)
  }
  const references = source.matchAll(/(?:href|xlink:href)\s*=\s*["']([^"']*)["']/gi)
  for (const match of references) {
    if (!match[1]!.startsWith("#")) {
      throw new PluginsError(
        "invalid",
        `Plugin ${pluginId} SVG icon contains an external reference`
      )
    }
  }
  const urls = source.matchAll(/url\(\s*["']?([^)'"\s]+)["']?\s*\)/gi)
  for (const match of urls) {
    if (!match[1]!.startsWith("#")) {
      throw new PluginsError("invalid", `Plugin ${pluginId} SVG icon contains an external resource`)
    }
  }
}

const readBoundedBody = async (pluginId: string, response: Response): Promise<Uint8Array> => {
  const reader = response.body?.getReader()
  if (reader === undefined) {
    return new Uint8Array()
  }
  const chunks: Uint8Array[] = []
  let byteLength = 0
  while (true) {
    const result = await reader.read()
    if (result.done) {
      break
    }
    byteLength += result.value.byteLength
    if (byteLength > MAX_PLUGIN_ICON_BYTES) {
      await reader.cancel()
      throw new PluginsError(
        "invalid",
        `Plugin ${pluginId} icon exceeds ${MAX_PLUGIN_ICON_BYTES} bytes`
      )
    }
    chunks.push(result.value)
  }
  const data = new Uint8Array(byteLength)
  let offset = 0
  for (const chunk of chunks) {
    data.set(chunk, offset)
    offset += chunk.byteLength
  }
  return data
}

/// Normalize every supported source format to a bounded, high-resolution PNG.
/// Clients therefore use their ordinary native raster-image path and never
/// need a platform-specific runtime SVG implementation.
const normalizeIcon = async (
  pluginId: string,
  contentType: PluginIconSourceContentType,
  data: Uint8Array
): Promise<PluginIconAsset> => {
  if (contentType === "image/svg+xml") {
    validateSvg(pluginId, data)
  }
  try {
    const { default: sharp } = await import("sharp")
    const normalized = await sharp(data, {
      density: contentType === "image/svg+xml" ? 192 : 72,
      limitInputPixels: 16_777_216
    })
      .rotate()
      .resize({ fit: "inside", height: 256, width: 256 })
      .png({ compressionLevel: 9 })
      .toBuffer()
    return { contentType: "image/png", data: new Uint8Array(normalized) }
  } catch (cause) {
    throw new PluginsError(
      "invalid",
      `Plugin ${pluginId} icon could not be decoded: ${
        cause instanceof Error
          ? cause.message
          : /* v8 ignore next -- sharp rejects with Error objects. */ String(cause)
      }`
    )
  }
}

export const fetchPluginIcon = async (
  options: FetchPluginIconOptions
): Promise<PluginIconAsset> => {
  const { paneType, plugin, timeoutMs } = options
  const path = iconPath(plugin, paneType)
  const port = await options.ensureRunning()
  let response: Response
  try {
    response = await (options.fetchImpl ?? globalThis.fetch)(`http://127.0.0.1:${port}${path}`, {
      headers: {
        accept: "image/svg+xml,image/png,image/webp",
        ...options.signedContextHeaders({
          paneType,
          pluginId: plugin.id,
          purpose: "icon"
        })
      },
      signal: AbortSignal.timeout(timeoutMs)
    })
  } catch (cause) {
    options.markUnreachable()
    if (cause instanceof Error && cause.name === "TimeoutError") {
      throw new PluginsError(
        "unavailable",
        `Plugin ${plugin.id} icon did not respond within ${timeoutMs}ms`
      )
    }
    throw new PluginsError(
      "unavailable",
      `Plugin ${plugin.id} icon request failed: ${
        cause instanceof Error
          ? cause.message
          : /* v8 ignore next -- fetch implementations reject with Error objects. */ String(cause)
      }`
    )
  }
  options.noteSuccess()
  if (!response.ok) {
    throw new PluginsError("invalid", `Plugin ${plugin.id} icon failed (HTTP ${response.status})`)
  }
  const contentType = response.headers.get("content-type")?.split(";", 1)[0]?.trim()
  if (!contentTypes.has(contentType as PluginIconSourceContentType)) {
    throw new PluginsError(
      "invalid",
      `Plugin ${plugin.id} icon must be SVG, PNG, or WebP (received ${contentType ?? "no Content-Type"})`
    )
  }
  const declaredLength = Number(response.headers.get("content-length"))
  if (Number.isFinite(declaredLength) && declaredLength > MAX_PLUGIN_ICON_BYTES) {
    throw new PluginsError(
      "invalid",
      `Plugin ${plugin.id} icon exceeds ${MAX_PLUGIN_ICON_BYTES} bytes`
    )
  }
  const data = await readBoundedBody(plugin.id, response)
  return normalizeIcon(plugin.id, contentType as PluginIconSourceContentType, data)
}
