import { EventEmitter, once } from "node:events"
import { createServer, type AddressInfo, type Socket } from "node:net"
import {
  BYTE_STREAM_INITIAL_CREDIT_BYTES,
  BYTE_STREAM_MAX_CHUNK_BYTES,
  byteStreamSealedBytes,
  codevisorLoopbackParams,
  type IncomingChannel
} from "@codevisor/cloud-client"
import type { ChannelCloseReason } from "@codevisor/api"
import { afterEach, describe, expect, it, vi } from "vitest"
import { byteStreamChannelHandler } from "./cloud-byte-stream.js"

class FakeChannel implements IncomingChannel {
  channelId = "channel-1"
  peerId = "app-1"
  channelType = "byte-stream"
  params: unknown = codevisorLoopbackParams()
  flowControlRequested = false
  deferred = false
  sent: Uint8Array[] = []
  grants: number[] = []
  closes: ChannelCloseReason[] = []
  onData: ((value: unknown, sealedBytes: number) => void) | null = null
  onBytes: ((value: Uint8Array, sealedBytes: number) => void) | null = null
  onCredit: ((bytes: number) => void) | null = null
  onOutboundDrain: (() => void) | null = null
  onClosed: ((reason: ChannelCloseReason | "peer-gone") => void) | null = null

  send(): void {}
  queuedOutboundBytes(): number {
    return 0
  }
  sendBytes(value: Uint8Array): number | undefined {
    this.sent.push(new Uint8Array(value))
    return byteStreamSealedBytes(value.byteLength)
  }
  deferInboundCredit(): void {
    this.deferred = true
  }
  grantCredit(bytes: number): void {
    this.grants.push(bytes)
  }
  close(reason: ChannelCloseReason): void {
    this.closes.push(reason)
  }
}

class FakeLoopbackSocket extends EventEmitter {
  destroyed = false
  ended = false
  pauses = 0
  resumes = 0
  writes: Uint8Array[] = []
  writeError: Error | undefined

  pause(): this {
    this.pauses += 1
    return this
  }

  resume(): this {
    this.resumes += 1
    return this
  }

  destroy(): this {
    this.destroyed = true
    return this
  }

  end(callback?: () => void): this {
    this.ended = true
    callback?.()
    return this
  }

  write(value: Uint8Array, callback?: (error?: Error) => void): boolean {
    this.writes.push(new Uint8Array(value))
    callback?.(this.writeError)
    return true
  }
}

describe("cloud byte stream loopback connector", () => {
  const cleanup: (() => Promise<void>)[] = []

  afterEach(async () => {
    await cleanup
      .splice(0)
      .toReversed()
      .reduce(async (previous, close) => {
        await previous
        await close()
      }, Promise.resolve())
  })

  const listen = async (): Promise<{
    url: string
    socket: Promise<Socket>
  }> => {
    let accept!: (socket: Socket) => void
    const socket = new Promise<Socket>((resolve) => {
      accept = resolve
    })
    const server = createServer((accepted) => accept(accepted))
    server.listen(0, "127.0.0.1")
    await once(server, "listening")
    const address = server.address() as AddressInfo
    cleanup.push(
      () =>
        new Promise((resolve) => {
          server.close(() => resolve())
        })
    )
    return { url: `http://127.0.0.1:${address.port}`, socket }
  }

  const fakeConnection = (
    channel = new FakeChannel(),
    url = "http://127.0.0.1:9000",
    log: (line: string) => void = () => undefined
  ): { channel: FakeChannel; socket: FakeLoopbackSocket } => {
    const socket = new FakeLoopbackSocket()
    byteStreamChannelHandler(url, log, () => socket as unknown as Socket)(channel)
    return { channel, socket }
  }

  it("rejects arbitrary services and non-loopback targets before dialing", () => {
    const dial = vi.fn(() => {
      throw new Error("must not dial")
    })
    const wrongService = new FakeChannel()
    wrongService.params = { service: "arbitrary-tcp", host: "example.com", port: 443 }
    byteStreamChannelHandler("http://127.0.0.1:9000", () => undefined, dial)(wrongService)
    expect(wrongService.closes).toEqual(["rejected"])

    const remoteTarget = new FakeChannel()
    byteStreamChannelHandler("https://example.com:443", () => undefined, dial)(remoteTarget)
    expect(remoteTarget.closes).toEqual(["rejected"])
    expect(dial).not.toHaveBeenCalled()
  })

  it("accepts only valid HTTP loopback URL forms", () => {
    const accepted = [
      ["http://[::1]", { host: "::1", port: 80, allowHalfOpen: true }],
      ["http://localhost:8123", { host: "localhost", port: 8123, allowHalfOpen: true }]
    ] as const
    for (const [url, expected] of accepted) {
      const socket = new FakeLoopbackSocket()
      const dial = vi.fn(() => socket as unknown as Socket)
      byteStreamChannelHandler(url, () => undefined, dial)(new FakeChannel())
      expect(dial).toHaveBeenCalledWith(expected)
    }

    for (const url of ["not a URL", "http://example.com", "http://localhost:0"]) {
      const channel = new FakeChannel()
      const dial = vi.fn(() => new FakeLoopbackSocket() as unknown as Socket)
      byteStreamChannelHandler(url, () => undefined, dial)(channel)
      expect(channel.closes).toEqual(["rejected"])
      expect(dial).not.toHaveBeenCalled()
    }
  })

  it("forwards exact bytes, obeys outbound credit, and propagates FIN", async () => {
    const target = await listen()
    const channel = new FakeChannel()
    byteStreamChannelHandler(target.url, () => undefined)(channel)
    const socket = await target.socket
    cleanup.push(async () => {
      socket.destroy()
    })

    await vi.waitFor(() => expect(channel.grants).toEqual([BYTE_STREAM_INITIAL_CREDIT_BYTES]))
    expect(channel.deferred).toBe(true)

    const received: Buffer[] = []
    socket.on("data", (data) => received.push(Buffer.from(data)))
    const request = new Uint8Array([0, 1, 2, 253, 254, 255])
    const requestCost = byteStreamSealedBytes(request.byteLength)
    channel.onBytes?.(request, requestCost)
    await vi.waitFor(() => expect(Buffer.concat(received)).toEqual(Buffer.from(request)))
    await vi.waitFor(() => expect(channel.grants).toContain(requestCost))

    const response = Buffer.from(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nlive\r\n"
    )
    socket.write(response)
    await new Promise((resolve) => setImmediate(resolve))
    expect(channel.sent).toEqual([])

    channel.onCredit?.(byteStreamSealedBytes(response.byteLength))
    await vi.waitFor(() => expect(channel.sent).toEqual([new Uint8Array(response)]))

    socket.end()
    await new Promise((resolve) => setImmediate(resolve))
    expect(channel.sent).toHaveLength(1)
    channel.onCredit?.(byteStreamSealedBytes(0))
    await vi.waitFor(() => expect(channel.sent.at(-1)).toEqual(new Uint8Array()))

    channel.onBytes?.(new Uint8Array(), byteStreamSealedBytes(0))
    await vi.waitFor(() => expect(channel.closes).toContain("done"))
  })

  it("destroys the local socket when the relay peer disappears", async () => {
    const target = await listen()
    const channel = new FakeChannel()
    byteStreamChannelHandler(target.url, () => undefined)(channel)
    const socket = await target.socket
    channel.onClosed?.("peer-gone")
    await once(socket, "close")
    expect(socket.destroyed).toBe(true)
  })

  it("stops an outbound stream when the relay can no longer accept bytes", () => {
    const { channel, socket } = fakeConnection()
    const response = Buffer.from("stream data")
    vi.spyOn(channel, "sendBytes").mockReturnValueOnce(undefined)

    socket.emit("data", response)
    channel.onCredit?.(byteStreamSealedBytes(response.byteLength))

    expect(socket.destroyed).toBe(true)
    expect(channel.closes).toEqual([])
    channel.onCredit?.(1)
    expect(socket.resumes).toBe(0)
  })

  it("rejects an inconsistent outbound ciphertext cost", () => {
    const { channel, socket } = fakeConnection()
    const response = Buffer.from("stream data")
    vi.spyOn(channel, "sendBytes").mockReturnValueOnce(
      byteStreamSealedBytes(response.byteLength) + 1
    )

    socket.emit("data", response)
    channel.onCredit?.(byteStreamSealedBytes(response.byteLength))

    expect(channel.closes).toEqual(["protocol-error"])
    expect(socket.destroyed).toBe(true)
  })

  it("stops when the relay closes while sending the local FIN", () => {
    const { channel, socket } = fakeConnection()
    vi.spyOn(channel, "sendBytes").mockReturnValueOnce(undefined)

    socket.emit("end")
    channel.onCredit?.(byteStreamSealedBytes(0))

    expect(socket.destroyed).toBe(true)
    expect(channel.closes).toEqual([])
  })

  it("rejects credit overflow and malformed or post-FIN inbound data", () => {
    const overflow = fakeConnection()
    overflow.channel.onCredit?.(Number.MAX_SAFE_INTEGER)
    overflow.channel.onCredit?.(1)
    expect(overflow.channel.closes).toEqual(["protocol-error"])
    expect(overflow.socket.destroyed).toBe(true)

    const malformed = fakeConnection()
    malformed.channel.onBytes?.(new Uint8Array([1]), 1)
    expect(malformed.channel.closes).toEqual(["protocol-error"])
    expect(malformed.socket.destroyed).toBe(true)

    const postFin = fakeConnection()
    postFin.channel.onBytes?.(new Uint8Array(), byteStreamSealedBytes(0))
    postFin.channel.onBytes?.(new Uint8Array([1]), byteStreamSealedBytes(1))
    expect(postFin.channel.closes).toEqual(["protocol-error"])
    expect(postFin.socket.ended).toBe(true)
  })

  it("rejects a failed local write without restoring inbound credit", () => {
    const { channel, socket } = fakeConnection()
    socket.writeError = new Error("write failed")
    const request = new Uint8Array([1, 2, 3])

    channel.onBytes?.(request, byteStreamSealedBytes(request.byteLength))

    expect(channel.closes).toEqual(["rejected"])
    expect(channel.grants).toEqual([])
    expect(socket.destroyed).toBe(true)
  })

  it("ignores a late connect and handles string data and socket failures", () => {
    const late = fakeConnection()
    late.channel.onClosed?.("peer-gone")
    late.socket.emit("connect")
    expect(late.channel.grants).toEqual([])

    const strings = fakeConnection()
    strings.channel.onCredit?.(byteStreamSealedBytes(3))
    strings.socket.emit("data", "abc")
    expect(strings.channel.sent).toEqual([new Uint8Array(Buffer.from("abc"))])

    const logs: string[] = []
    const failed = fakeConnection(new FakeChannel(), "http://127.0.0.1:9000", (line) =>
      logs.push(line)
    )
    failed.socket.emit("error", new Error("connection reset"))
    expect(logs).toEqual(["Cloud byte stream failed: connection reset"])
    expect(failed.channel.closes).toEqual(["rejected"])
    expect(failed.socket.destroyed).toBe(true)

    const erroredClose = fakeConnection()
    erroredClose.socket.emit("close", true)
    expect(erroredClose.channel.closes).toEqual(["rejected"])
  })

  it("splits large local reads into bounded relay messages", () => {
    const { channel, socket } = fakeConnection()
    const response = Buffer.alloc(BYTE_STREAM_MAX_CHUNK_BYTES + 1, 7)
    channel.onCredit?.(
      byteStreamSealedBytes(BYTE_STREAM_MAX_CHUNK_BYTES) + byteStreamSealedBytes(1)
    )

    socket.emit("data", response)

    expect(channel.sent.map((bytes) => bytes.byteLength)).toEqual([BYTE_STREAM_MAX_CHUNK_BYTES, 1])
  })
})
