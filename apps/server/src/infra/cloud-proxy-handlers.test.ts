import { createHash } from "node:crypto"
import { once } from "node:events"
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http"
import type { AddressInfo } from "node:net"

import type { ChannelCloseReason } from "@codevisor/api"
import {
  MAX_REQUEST_BODY_BYTES,
  PROXY_INITIAL_CREDIT_BYTES,
  type IncomingChannel
} from "@codevisor/cloud-client"
import { afterEach, describe, expect, it } from "vitest"

import { httpChannelHandler, streamedRequestBody } from "./cloud-proxy-handlers.js"

class FakeChannel implements IncomingChannel {
  channelId = "channel-1"
  peerId = "app-1"
  channelType = "http"
  params: unknown
  flowControlRequested: boolean
  sent: unknown[] = []
  grants: number[] = []
  readonly closed: Promise<ChannelCloseReason>
  #resolveClosed!: (reason: ChannelCloseReason) => void
  onData: ((value: unknown, sealedBytes: number) => void) | null = null
  onBytes: ((value: Uint8Array, sealedBytes: number) => void) | null = null
  onCredit: ((bytes: number) => void) | null = null
  onOutboundDrain: (() => void) | null = null
  onClosed: ((reason: ChannelCloseReason | "peer-gone") => void) | null = null

  constructor(path: string, flowControlRequested: boolean) {
    this.params = { method: "POST", path, headers: { "content-type": "video/mp4" } }
    this.flowControlRequested = flowControlRequested
    this.closed = new Promise((resolve) => (this.#resolveClosed = resolve))
  }

  send(value: unknown): void {
    this.sent.push(value)
  }
  sendBytes(): number | undefined {
    return undefined
  }
  deferInboundCredit(): void {}
  grantCredit(bytes: number): void {
    this.grants.push(bytes)
  }
  queuedOutboundBytes(): number {
    return 0
  }
  close(reason: ChannelCloseReason): void {
    this.#resolveClosed(reason)
  }
  chunk(bytes: Uint8Array, sealedBytes = bytes.byteLength + 16): void {
    this.onData?.({ kind: "chunk", data: Buffer.from(bytes).toString("base64url") }, sealedBytes)
  }
  end(): void {
    this.onData?.({ kind: "end" }, 16)
  }
  responseBody(): string {
    return Buffer.concat(
      this.sent
        .filter((frame): frame is { kind: "chunk"; data: string } => {
          return (frame as { kind?: string }).kind === "chunk"
        })
        .map((frame) => Buffer.from(frame.data, "base64url"))
    ).toString()
  }
}

const servers: Server[] = []
afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => new Promise((r) => server.close(r))))
})

const localServer = async (
  handler: (request: IncomingMessage, response: ServerResponse) => void
): Promise<string> => {
  const server = createServer(handler)
  servers.push(server)
  server.listen(0, "127.0.0.1")
  await once(server, "listening")
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`
}

/// Answers with the byte count and sha256 of the body it read.
const digestingServer = (): Promise<string> =>
  localServer((request, response) => {
    const hash = createHash("sha256")
    let bytes = 0
    request.on("data", (chunk: Buffer) => {
      bytes += chunk.byteLength
      hash.update(chunk)
    })
    request.on("end", () => response.end(`${bytes}:${hash.digest("hex")}`))
  })

describe("streamedRequestBody", () => {
  it("grants a chunk's credit only when the consumer pulls it", async () => {
    const grants: number[] = []
    const body = streamedRequestBody((bytes) => grants.push(bytes))
    body.push(new Uint8Array([1]), 17)
    body.push(new Uint8Array([2, 2]), 18)
    expect(grants).toEqual([])

    const reader = body.stream.getReader()
    expect((await reader.read()).value).toEqual(new Uint8Array([1]))
    expect(grants).toEqual([17])
    expect((await reader.read()).value).toEqual(new Uint8Array([2, 2]))
    expect(grants).toEqual([17, 18])

    // A pull with nothing queued waits for the next chunk or the end.
    const pending = reader.read()
    body.push(new Uint8Array([3]), 19)
    expect((await pending).value).toEqual(new Uint8Array([3]))
    body.end()
    expect((await reader.read()).done).toBe(true)
    expect(grants).toEqual([17, 18, 19])
  })

  it("errors the body when the channel dies mid-upload", async () => {
    const body = streamedRequestBody(() => undefined)
    const reader = body.stream.getReader()
    const pending = reader.read()
    body.fail(new Error("channel closed"))
    await expect(pending).rejects.toThrow("channel closed")
  })
})

describe("httpChannelHandler", () => {
  it("streams a flow-controlled upload larger than the buffered cap", async () => {
    const channel = new FakeChannel("/v1/files", true)
    httpChannelHandler(await digestingServer(), () => undefined)(channel)
    expect(channel.grants).toEqual([PROXY_INITIAL_CREDIT_BYTES])

    const chunk = new Uint8Array(256 * 1024).fill(0x5a)
    const chunks = MAX_REQUEST_BODY_BYTES / chunk.byteLength + 4
    const expected = createHash("sha256")
    for (let index = 0; index < chunks; index += 1) {
      channel.chunk(chunk)
      expected.update(chunk)
    }
    channel.end()

    expect(await channel.closed).toBe("done")
    expect(channel.sent[0]).toMatchObject({ kind: "head", status: 200 })
    expect(channel.responseBody()).toBe(`${chunks * chunk.byteLength}:${expected.digest("hex")}`)
    // Every chunk's credit came back once the local request consumed it.
    expect(channel.grants.slice(1)).toEqual(Array(chunks).fill(chunk.byteLength + 16))
  })

  it("aborts the local request when the channel closes mid-upload", async () => {
    const aborted = Promise.withResolvers<void>()
    const started = Promise.withResolvers<void>()
    const base = await localServer((request) => {
      request.once("data", () => started.resolve())
      request.once("close", () => {
        if (!request.complete) aborted.resolve()
      })
    })
    const channel = new FakeChannel("/v1/files", true)
    httpChannelHandler(base, () => undefined)(channel)
    channel.chunk(new Uint8Array(1024))
    await started.promise
    channel.onClosed?.("peer-gone")
    await aborted.promise
  })

  it("relays an early rejection while the app is still uploading", async () => {
    const base = await localServer((request, response) => {
      request.once("data", () => {
        response.writeHead(413, { "content-type": "application/json" })
        response.end('{"code":"file_too_large"}')
      })
    })
    const channel = new FakeChannel("/v1/files", true)
    httpChannelHandler(base, () => undefined)(channel)
    channel.chunk(new Uint8Array(1024))
    expect(await channel.closed).toBe("done")
    expect(channel.sent[0]).toMatchObject({ kind: "head", status: 413 })
    expect(channel.responseBody()).toBe('{"code":"file_too_large"}')
    // Chunks still in flight from the app are dropped, not replayed.
    channel.chunk(new Uint8Array(1024))
    channel.end()
    expect(channel.sent.at(-1)).toEqual({ kind: "end" })
  })

  it("still buffers, and caps, bodies from openers without flow control", async () => {
    const channel = new FakeChannel("/v1/files", false)
    httpChannelHandler(await digestingServer(), () => undefined)(channel)
    channel.chunk(new Uint8Array(3).fill(1))
    channel.end()
    expect(await channel.closed).toBe("done")
    expect(channel.grants).toEqual([])
    expect(channel.responseBody()).toMatch(/^3:/)

    const oversized = new FakeChannel("/v1/files", false)
    httpChannelHandler(await digestingServer(), () => undefined)(oversized)
    oversized.chunk(new Uint8Array(MAX_REQUEST_BODY_BYTES + 1))
    expect(await oversized.closed).toBe("rejected")
  })
})
