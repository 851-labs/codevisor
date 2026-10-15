import { isPlainRecord } from "@codevisor/api"
import { fromBase64Url, toBase64Url } from "@codevisor/cloud-crypto"

export const HTTP_CHANNEL_TYPE = "http"
export const WS_CHANNEL_TYPE = "ws"

export const MAX_CHUNK_BYTES = 262144
export const MAX_REQUEST_BODY_BYTES = 32 * 1024 * 1024

export const PROXY_INITIAL_CREDIT_BYTES = 1024 * 1024
export const PROXY_OUTBOUND_HIGH_WATER_BYTES = 512 * 1024

const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "host",
  "content-length",
  "transfer-encoding",
  "upgrade",
  "keep-alive"
])

const isHeaderRecord = (value: unknown): value is Record<string, string> =>
  isPlainRecord(value) && Object.values(value).every((entry) => typeof entry === "string")

const isRelayPath = (value: unknown): value is string =>
  typeof value === "string" && value.startsWith("/")

export interface HttpChannelParams {
  readonly method: string
  readonly path: string
  readonly headers: Record<string, string>
}

export const parseHttpChannelParams = (value: unknown): HttpChannelParams | undefined => {
  if (!isPlainRecord(value)) return undefined
  const { method, path, headers } = value
  if (typeof method !== "string" || method === "") return undefined
  if (!isRelayPath(path)) return undefined
  if (!isHeaderRecord(headers)) return undefined
  return { method, path, headers }
}

export interface WsChannelParams {
  readonly path: string
}

export const parseWsChannelParams = (value: unknown): WsChannelParams | undefined => {
  if (!isPlainRecord(value) || !isRelayPath(value.path)) return undefined
  return { path: value.path }
}

export type HttpRequestFrame = { kind: "chunk"; data: Uint8Array } | { kind: "end" }

export const parseHttpRequestFrame = (value: unknown): HttpRequestFrame | undefined => {
  if (!isPlainRecord(value)) return undefined
  if (value.kind === "end") return { kind: "end" }
  if (value.kind !== "chunk" || typeof value.data !== "string") return undefined
  try {
    return { kind: "chunk", data: fromBase64Url(value.data) }
  } catch {
    return undefined
  }
}

export interface HttpChunkFrame {
  readonly kind: "chunk"
  readonly data: string
}

export const chunkFrames = (bytes: Uint8Array, cap = MAX_CHUNK_BYTES): HttpChunkFrame[] => {
  const frames: HttpChunkFrame[] = []
  for (let offset = 0; offset < bytes.byteLength; offset += cap) {
    frames.push({ kind: "chunk", data: toBase64Url(bytes.subarray(offset, offset + cap)) })
  }
  return frames
}

export interface HttpHeadFrame {
  readonly kind: "head"
  readonly status: number
  readonly headers: Record<string, string>
}

export const headFrame = (status: number, headers: Iterable<[string, string]>): HttpHeadFrame => ({
  kind: "head",
  status,
  headers: sanitizeResponseHeaders(headers)
})

export const sanitizeRequestHeaders = (headers: Record<string, string>): Record<string, string> => {
  const sanitized: Record<string, string> = {}
  for (const [name, value] of Object.entries(headers)) {
    const lower = name.toLowerCase()
    if (HOP_BY_HOP_HEADERS.has(lower) || lower === "authorization") continue
    sanitized[lower] = value
  }
  return sanitized
}

const sanitizeResponseHeaders = (headers: Iterable<[string, string]>): Record<string, string> => {
  const sanitized: Record<string, string> = {}
  for (const [name, value] of headers) {
    const lower = name.toLowerCase()
    if (HOP_BY_HOP_HEADERS.has(lower) || lower === "content-encoding") continue
    sanitized[lower] = value
  }
  return sanitized
}

export interface BodyBuffer {
  chunks: Uint8Array[]
  totalBytes: number
}

export const emptyBodyBuffer = (): BodyBuffer => ({ chunks: [], totalBytes: 0 })

export const appendBodyChunk = (
  buffer: BodyBuffer,
  chunk: Uint8Array,
  cap = MAX_REQUEST_BODY_BYTES
): boolean => {
  if (buffer.totalBytes + chunk.byteLength > cap) return false
  buffer.chunks.push(chunk)
  buffer.totalBytes += chunk.byteLength
  return true
}

export const concatBodyBuffer = (buffer: BodyBuffer): Uint8Array<ArrayBuffer> => {
  const bytes = new Uint8Array(buffer.totalBytes)
  let offset = 0
  for (const chunk of buffer.chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  return bytes
}

export type WsFrame = { kind: "text"; data: string } | { kind: "binary"; data: Uint8Array }

export const parseWsFrame = (value: unknown): WsFrame | undefined => {
  if (!isPlainRecord(value)) return undefined
  if (value.kind === "text") {
    return typeof value.data === "string" ? { kind: "text", data: value.data } : undefined
  }
  if (value.kind !== "binary" || typeof value.data !== "string") return undefined
  try {
    return { kind: "binary", data: fromBase64Url(value.data) }
  } catch {
    return undefined
  }
}

export interface WsWireFrame {
  readonly kind: "text" | "binary" | "part" | "text-end" | "binary-end"
  readonly data: string
}

export const encodeWsFrames = (data: string | Uint8Array, cap = MAX_CHUNK_BYTES): WsWireFrame[] => {
  const isText = typeof data === "string"
  const bytes = isText ? new TextEncoder().encode(data) : data
  if (bytes.byteLength <= cap) {
    return [isText ? { kind: "text", data } : { kind: "binary", data: toBase64Url(bytes) }]
  }
  const frames: WsWireFrame[] = []
  for (let offset = 0; offset < bytes.byteLength; offset += cap) {
    const piece = toBase64Url(bytes.subarray(offset, offset + cap))
    const isLast = offset + cap >= bytes.byteLength
    frames.push(
      isLast
        ? { kind: isText ? "text-end" : "binary-end", data: piece }
        : { kind: "part", data: piece }
    )
  }
  return frames
}
