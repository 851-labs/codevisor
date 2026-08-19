import { createServer } from "node:net"
import { Socket } from "node:net"
import type { IncomingMessage } from "node:http"
import { describe, expect, it } from "vitest"
import { spliceUpgrade } from "./plugin-proxy.js"

/// Reserves a loopback port that nothing listens on.
const closedPort = (): Promise<number> =>
  new Promise((resolve) => {
    const probe = createServer()
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address()
      const port = typeof address === "object" && address !== null ? address.port : 0
      probe.close(() => resolve(port))
    })
  })

describe("spliceUpgrade", () => {
  it("destroys both sockets when the plugin connection fails, reporting one close", async () => {
    const port = await closedPort()
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
    await expect.poll(() => client.destroyed).toBe(true)
    // Both sides close, but the pin release must fire exactly once.
    await expect.poll(() => closes).toBe(1)
    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(closes).toBe(1)
  })

  it("forwards buffered head bytes and rewrites headers", async () => {
    const received: Array<Buffer> = []
    const upstream = createServer()
    upstream.on("connection", (socket) => {
      socket.on("data", (chunk) => received.push(Buffer.from(chunk)))
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
    await expect.poll(() => Buffer.concat(received).toString("utf8")).toContain("head-bytes")
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
