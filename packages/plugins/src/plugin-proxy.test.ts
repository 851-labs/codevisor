import * as net from "node:net"
import { createServer } from "node:net"
import { Socket } from "node:net"
import type { IncomingMessage } from "node:http"
import { afterEach, describe, expect, it, vi } from "vitest"
import { spliceUpgrade } from "./plugin-proxy.js"

vi.mock("node:net", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:net")>()
  return { ...actual, connect: vi.fn(actual.connect) }
})

describe("spliceUpgrade", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    vi.resetAllMocks()
  })
  it("destroys both sockets when the plugin connection fails, reporting one close", async () => {
    const port = 4321
    const upstream = new Socket()
    vi.spyOn(net, "connect").mockReturnValue(upstream)
    const client = new Socket()
    const request = {
      method: "GET",
      rawHeaders: ["Upgrade", "websocket", "Connection", "Upgrade"]
    } as unknown as IncomingMessage
    let closes = 0
    spliceUpgrade({
      contextHeaders: {},
      head: Buffer.from([]),
      onClose: () => {
        closes += 1
      },
      port,
      request,
      socket: client,
      targetPath: "/live"
    })
    const clientClosed = new Promise<void>((resolve) => client.once("close", resolve))
    const upstreamClosed = new Promise<void>((resolve) => upstream.once("close", resolve))
    upstream.emit("error", new Error("connection refused"))
    await Promise.all([clientClosed, upstreamClosed])
    expect(client.destroyed).toBe(true)
    expect(upstream.destroyed).toBe(true)
    // Repeated closure notifications still release the pin once.
    upstream.emit("close")
    client.emit("close")
    expect(closes).toBe(1)
  })

  it("forwards buffered head bytes and rewrites headers", async () => {
    const received: Array<Buffer> = []
    const forwarded = Promise.withResolvers<void>()
    const upstream = createServer()
    upstream.on("connection", (socket) => {
      socket.on("data", (chunk) => {
        received.push(Buffer.from(chunk))
        if (Buffer.concat(received).includes("head-bytes")) forwarded.resolve()
      })
    })
    await new Promise<void>((resolve) => upstream.listen(0, "127.0.0.1", resolve))
    const address = upstream.address()
    const port = typeof address === "object" && address !== null ? address.port : 0
    const client = new Socket()
    const request = {
      method: "GET",
      rawHeaders: [
        "Host",
        "example.test",
        "Authorization",
        "Bearer secret",
        "Cookie",
        "codevisor-plugin-x=token",
        "Upgrade",
        "websocket"
      ]
    } as unknown as IncomingMessage
    spliceUpgrade({
      contextHeaders: { "x-codevisor-context": "ctx" },
      head: Buffer.from("head-bytes"),
      port,
      request,
      socket: client,
      targetPath: "/live?x=1"
    })
    await forwarded.promise
    const written = Buffer.concat(received).toString("utf8")
    expect(written).toContain("GET /live?x=1 HTTP/1.1")
    expect(written).toContain(`Host: 127.0.0.1:${port}`)
    expect(written).toContain("x-codevisor-context: ctx")
    expect(written).toContain("Upgrade: websocket")
    expect(written).not.toContain("Authorization")
    expect(written).not.toContain("Cookie")
    client.destroy()
    upstream.close()
  })
})
