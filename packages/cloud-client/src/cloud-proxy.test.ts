import { fromBase64Url, toBase64Url } from "@codevisor/cloud-crypto"
import { describe, expect, it } from "vitest"
import {
  appendBodyChunk,
  chunkFrames,
  concatBodyBuffer,
  emptyBodyBuffer,
  encodeWsFrame,
  encodeWsFrames,
  headFrame,
  MAX_CHUNK_BYTES,
  MAX_REQUEST_BODY_BYTES,
  parseHttpChannelParams,
  parseHttpRequestFrame,
  parseWsChannelParams,
  parseWsFrame,
  sanitizeRequestHeaders,
  sanitizeResponseHeaders
} from "./cloud-proxy.js"

const bytes = (...values: number[]): Uint8Array => Uint8Array.from(values)

describe("http channel params", () => {
  it("accepts a well-formed open payload", () => {
    expect(
      parseHttpChannelParams({
        method: "POST",
        path: "/v1/info?verbose=1",
        headers: { accept: "application/json" }
      })
    ).toEqual({
      method: "POST",
      path: "/v1/info?verbose=1",
      headers: { accept: "application/json" }
    })
  })

  it("rejects malformed payloads", () => {
    expect(parseHttpChannelParams(null)).toBeUndefined()
    expect(parseHttpChannelParams("GET /")).toBeUndefined()
    expect(parseHttpChannelParams([])).toBeUndefined()
    expect(parseHttpChannelParams({ method: 5, path: "/", headers: {} })).toBeUndefined()
    expect(parseHttpChannelParams({ method: "", path: "/", headers: {} })).toBeUndefined()
    expect(parseHttpChannelParams({ method: "GET", path: "v1/info", headers: {} })).toBeUndefined()
    expect(parseHttpChannelParams({ method: "GET", path: 7, headers: {} })).toBeUndefined()
    expect(parseHttpChannelParams({ method: "GET", path: "/", headers: "nope" })).toBeUndefined()
    expect(
      parseHttpChannelParams({ method: "GET", path: "/", headers: { accept: 42 } })
    ).toBeUndefined()
    expect(parseHttpChannelParams({ method: "GET", path: "/" })).toBeUndefined()
  })
})

describe("ws channel params", () => {
  it("accepts a well-formed open payload", () => {
    expect(parseWsChannelParams({ path: "/v1/events?since=3" })).toEqual({
      path: "/v1/events?since=3"
    })
  })

  it("rejects malformed payloads", () => {
    expect(parseWsChannelParams(undefined)).toBeUndefined()
    expect(parseWsChannelParams({ path: "v1/events" })).toBeUndefined()
    expect(parseWsChannelParams({ path: 1 })).toBeUndefined()
  })
})

describe("http request frames", () => {
  it("decodes chunk and end frames", () => {
    expect(parseHttpRequestFrame({ kind: "end" })).toEqual({ kind: "end" })
    expect(parseHttpRequestFrame({ kind: "chunk", data: toBase64Url(bytes(1, 2, 255)) })).toEqual({
      kind: "chunk",
      data: bytes(1, 2, 255)
    })
  })

  it("rejects malformed frames", () => {
    expect(parseHttpRequestFrame("end")).toBeUndefined()
    expect(parseHttpRequestFrame({ kind: "head" })).toBeUndefined()
    expect(parseHttpRequestFrame({ kind: "chunk", data: 3 })).toBeUndefined()
    expect(parseHttpRequestFrame({ kind: "chunk", data: "not base64url!" })).toBeUndefined()
  })
})

describe("response chunking", () => {
  it("emits nothing for an empty body", () => {
    expect(chunkFrames(bytes())).toEqual([])
  })

  it("keeps a small body in one frame under the default cap", () => {
    expect(chunkFrames(bytes(9, 8, 7))).toEqual([
      { kind: "chunk", data: toBase64Url(bytes(9, 8, 7)) }
    ])
    expect(MAX_CHUNK_BYTES).toBe(262144)
  })

  it("splits bodies into ≤cap frames", () => {
    expect(chunkFrames(bytes(1, 2, 3, 4, 5), 2)).toEqual([
      { kind: "chunk", data: toBase64Url(bytes(1, 2)) },
      { kind: "chunk", data: toBase64Url(bytes(3, 4)) },
      { kind: "chunk", data: toBase64Url(bytes(5)) }
    ])
  })
})

describe("header sanitization", () => {
  it("strips hop-by-hop and authorization headers from requests", () => {
    expect(
      sanitizeRequestHeaders({
        Connection: "keep-alive",
        Host: "hub.example",
        "Content-Length": "12",
        "Transfer-Encoding": "chunked",
        Upgrade: "websocket",
        "Keep-Alive": "timeout=5",
        Authorization: "Bearer cloud-session",
        "Content-Type": "application/json"
      })
    ).toEqual({ "content-type": "application/json" })
  })

  it("strips hop-by-hop and content-encoding headers from responses", () => {
    expect(
      sanitizeResponseHeaders([
        ["Connection", "close"],
        ["Content-Encoding", "gzip"],
        ["Content-Length", "5"],
        ["X-Custom", "kept"]
      ])
    ).toEqual({ "x-custom": "kept" })
  })

  it("builds a head frame with sanitized headers", () => {
    expect(
      headFrame(204, [
        ["Transfer-Encoding", "chunked"],
        ["ETag", '"abc"']
      ])
    ).toEqual({ kind: "head", status: 204, headers: { etag: '"abc"' } })
  })
})

describe("request body buffering", () => {
  it("accumulates chunks and concatenates them in order", () => {
    const buffer = emptyBodyBuffer()
    expect(appendBodyChunk(buffer, bytes(1, 2))).toBe(true)
    expect(appendBodyChunk(buffer, bytes(3))).toBe(true)
    expect(concatBodyBuffer(buffer)).toEqual(bytes(1, 2, 3))
    expect(MAX_REQUEST_BODY_BYTES).toBe(32 * 1024 * 1024)
  })

  it("refuses chunks past the cap without mutating the buffer", () => {
    const buffer = emptyBodyBuffer()
    expect(appendBodyChunk(buffer, bytes(1, 2, 3), 4)).toBe(true)
    expect(appendBodyChunk(buffer, bytes(4, 5), 4)).toBe(false)
    expect(appendBodyChunk(buffer, bytes(4), 4)).toBe(true)
    expect(concatBodyBuffer(buffer)).toEqual(bytes(1, 2, 3, 4))
  })
})

describe("ws frames", () => {
  it("decodes text and binary frames", () => {
    expect(parseWsFrame({ kind: "text", data: "hello" })).toEqual({ kind: "text", data: "hello" })
    expect(parseWsFrame({ kind: "binary", data: toBase64Url(bytes(0, 127, 255)) })).toEqual({
      kind: "binary",
      data: bytes(0, 127, 255)
    })
  })

  it("rejects malformed frames", () => {
    expect(parseWsFrame("hello")).toBeUndefined()
    expect(parseWsFrame({ kind: "text", data: 1 })).toBeUndefined()
    expect(parseWsFrame({ kind: "ping" })).toBeUndefined()
    expect(parseWsFrame({ kind: "binary", data: 1 })).toBeUndefined()
    expect(parseWsFrame({ kind: "binary", data: "=invalid=" })).toBeUndefined()
  })

  it("encodes outgoing messages by payload type", () => {
    expect(encodeWsFrame("hi")).toEqual({ kind: "text", data: "hi" })
    expect(encodeWsFrame(bytes(1, 2))).toEqual({ kind: "binary", data: toBase64Url(bytes(1, 2)) })
  })

  it("keeps small messages as single frames", () => {
    expect(encodeWsFrames("hi")).toEqual([{ kind: "text", data: "hi" }])
    expect(encodeWsFrames(bytes(1, 2, 3))).toEqual([
      { kind: "binary", data: toBase64Url(bytes(1, 2, 3)) }
    ])
  })

  it("splits oversized messages into parts closed by a typed end frame", () => {
    const textFrames = encodeWsFrames("abcdefgh", 3)
    expect(textFrames.map((frame) => frame.kind)).toEqual(["part", "part", "text-end"])
    const reassembled = textFrames.flatMap((frame) => [...fromBase64Url(frame.data)])
    expect(new TextDecoder().decode(Uint8Array.from(reassembled))).toBe("abcdefgh")

    const binaryFrames = encodeWsFrames(bytes(0, 1, 2, 3, 4, 5, 6), 3)
    expect(binaryFrames.map((frame) => frame.kind)).toEqual(["part", "part", "binary-end"])
    expect(binaryFrames.flatMap((frame) => [...fromBase64Url(frame.data)])).toEqual([
      0, 1, 2, 3, 4, 5, 6
    ])
  })

  it("survives split boundaries inside multi-byte code points", () => {
    // Three-byte characters with a 4-byte cap: every part boundary lands mid
    // code point; only the reassembled whole decodes correctly.
    const text = "€€€"
    const frames = encodeWsFrames(text, 4)
    expect(frames.length).toBeGreaterThan(1)
    const reassembled = frames.flatMap((frame) => [...fromBase64Url(frame.data)])
    expect(new TextDecoder().decode(Uint8Array.from(reassembled))).toBe(text)
  })
})
