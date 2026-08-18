import { fromBase64Url, toBase64Url } from "@codevisor/cloud-crypto"

/// Pure protocol logic for the generic cloud relay channels that expose this
/// machine's local HTTP/WS API to apps: open-params and frame
/// parsing/validation, response-body chunking, and hop-by-hop header
/// sanitization. The impure halves (fetch, `ws` sockets, channel plumbing)
/// live in cloud-bridge.ts.

export const HTTP_CHANNEL_TYPE = "http"
export const WS_CHANNEL_TYPE = "ws"

/// Raw byte cap per chunk frame, measured before base64url encoding.
export const MAX_CHUNK_BYTES = 262144
/// Total buffered request body cap; larger uploads are rejected.
export const MAX_REQUEST_BODY_BYTES = 32 * 1024 * 1024

/// Never relayed in either direction: they describe the hop (the relay
/// reframes bodies and owns its own connections), not the resource.
const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "host",
  "content-length",
  "transfer-encoding",
  "upgrade",
  "keep-alive"
])

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const isHeaderRecord = (value: unknown): value is Record<string, string> =>
  isRecord(value) && Object.values(value).every((entry) => typeof entry === "string")

const isRelayPath = (value: unknown): value is string =>
  typeof value === "string" && value.startsWith("/")

// -- Channel open params ------------------------------------------------------

export interface HttpChannelParams {
  readonly method: string
  readonly path: string
  readonly headers: Record<string, string>
}

export const parseHttpChannelParams = (value: unknown): HttpChannelParams | undefined => {
  if (!isRecord(value)) return undefined
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
  if (!isRecord(value) || !isRelayPath(value.path)) return undefined
  return { path: value.path }
}

// -- HTTP frames --------------------------------------------------------------

/// Opener→responder body frame, with chunk data decoded to raw bytes.
export type HttpRequestFrame = { kind: "chunk"; data: Uint8Array } | { kind: "end" }

export const parseHttpRequestFrame = (value: unknown): HttpRequestFrame | undefined => {
  if (!isRecord(value)) return undefined
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

/// Splits raw response bytes into base64url chunk frames of ≤cap raw bytes.
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

// -- Header sanitization ------------------------------------------------------

/// App→local-server direction. Also drops `authorization`: loopback requests
/// are exempt from token auth, and the app's cloud bearer must never reach
/// the local server.
export const sanitizeRequestHeaders = (headers: Record<string, string>): Record<string, string> => {
  const sanitized: Record<string, string> = {}
  for (const [name, value] of Object.entries(headers)) {
    const lower = name.toLowerCase()
    if (HOP_BY_HOP_HEADERS.has(lower) || lower === "authorization") continue
    sanitized[lower] = value
  }
  return sanitized
}

/// Local-server→app direction. Also drops `content-encoding`: fetch already
/// decoded the body, so relaying the header would corrupt the app's read.
export const sanitizeResponseHeaders = (
  headers: Iterable<[string, string]>
): Record<string, string> => {
  const sanitized: Record<string, string> = {}
  for (const [name, value] of headers) {
    const lower = name.toLowerCase()
    if (HOP_BY_HOP_HEADERS.has(lower) || lower === "content-encoding") continue
    sanitized[lower] = value
  }
  return sanitized
}

// -- Request body buffering ---------------------------------------------------

export interface BodyBuffer {
  chunks: Uint8Array[]
  totalBytes: number
}

export const emptyBodyBuffer = (): BodyBuffer => ({ chunks: [], totalBytes: 0 })

/// Returns false (leaving the buffer untouched) when the chunk would push the
/// buffered request body past the cap.
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

// -- WS frames ----------------------------------------------------------------

/// A relayed WebSocket message, with binary data decoded to raw bytes.
export type WsFrame = { kind: "text"; data: string } | { kind: "binary"; data: Uint8Array }

export const parseWsFrame = (value: unknown): WsFrame | undefined => {
  if (!isRecord(value)) return undefined
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

/// `text`/`binary` carry one whole message. Messages above the chunk cap are
/// split into `part` frames (base64url byte slices) closed by a typed
/// `text-end`/`binary-end` frame carrying the final slice — the receiver
/// concatenates and yields one message. Backward compatibility is deliberate:
/// apps that predate chunking ignore unknown kinds entirely, so an oversized
/// message degrades to one skipped message on old apps instead of tripping
/// the hub's frame cap and livelocking cursor replay for the whole channel.
export interface WsWireFrame {
  readonly kind: "text" | "binary" | "part" | "text-end" | "binary-end"
  readonly data: string
}

export const encodeWsFrame = (data: string | Uint8Array): WsWireFrame =>
  typeof data === "string" ? { kind: "text", data } : { kind: "binary", data: toBase64Url(data) }

/// Encodes one outbound WS message as one frame, or — above `cap` raw bytes —
/// as `part` frames closed by a typed end frame. Splitting works on UTF-8
/// bytes; parts may cut mid code point, which is safe because the receiver
/// decodes text only after reassembling the whole byte sequence.
export const encodeWsFrames = (data: string | Uint8Array, cap = MAX_CHUNK_BYTES): WsWireFrame[] => {
  const isText = typeof data === "string"
  const bytes = isText ? new TextEncoder().encode(data) : data
  if (bytes.byteLength <= cap) return [encodeWsFrame(data)]
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
