import { ClientRequest, IncomingMessage, request, ServerResponse } from "node:http"
import { connect } from "node:net"

import { afterEach, expect, it, vi } from "vitest"

import { FakeSocket } from "../test-support-net.js"
import { forwardBrowserHTTP, forwardBrowserUpgrade } from "./browser-forward-proxy.js"
import { BrowserProxy } from "./browser-proxy.js"

vi.mock("node:http", async (importOriginal) => ({
  ...(await importOriginal<typeof import("node:http")>()),
  request: vi.fn()
}))
vi.mock("node:net", async (importOriginal) => ({
  ...(await importOriginal<typeof import("node:net")>()),
  connect: vi.fn()
}))
afterEach(() => vi.clearAllMocks())

class FakeIncomingMessage extends IncomingMessage {
  readonly pipes: NodeJS.WritableStream[] = []

  constructor(socket = new FakeSocket()) {
    super(socket)
  }

  override pipe<T extends NodeJS.WritableStream>(destination: T): T {
    this.pipes.push(destination)
    return destination
  }
}

class FakeServerResponse extends ServerResponse {
  readonly heads: Array<[number, unknown]> = []
  endings = 0

  override writeHead(statusCode: number, headers?: unknown): this {
    this.heads.push([statusCode, headers])
    return this
  }

  override end(): this {
    this.endings += 1
    return this
  }

  override destroy(): this {
    if (!this.destroyed) {
      this.destroyed = true
      this.emit("close")
    }
    return this
  }
}

class FakeClientRequest extends ClientRequest {
  destroyError: Error | undefined

  constructor() {
    super({ createConnection: () => undefined })
  }

  override destroy(error?: Error): this {
    this.destroyError = error
    if (!this.destroyed) {
      this.destroyed = true
      this.emit("close")
    }
    return this
  }
}

const pageURL = "http://localhost:3000/page?q=1"

function fixture() {
  const upstream = new FakeClientRequest()
  const upstreamSocket = new FakeSocket()
  const client = new FakeSocket()
  const downstream = new FakeIncomingMessage(client)
  downstream.method = "GET"
  downstream.url = pageURL
  const response = new FakeServerResponse(downstream)
  const track = vi.fn()
  const failed = vi.fn()
  vi.mocked(request).mockReturnValue(upstream)
  vi.mocked(connect).mockReturnValue(upstreamSocket)
  const target = { host: "127.0.0.1", port: 3000, url: new URL(pageURL) }
  return {
    upstream,
    upstreamSocket,
    client,
    downstream,
    response,
    track,
    failed,
    http: () => forwardBrowserHTTP(downstream, response, target, track, failed),
    upgrade: (head = Buffer.alloc(0)) =>
      forwardBrowserUpgrade(downstream, client, head, target, track)
  }
}

it.each([false, true])("handles HTTP upstream failure after headers=%s", (headersSent) => {
  const { http, upstream, response, failed } = fixture()
  http()
  Object.defineProperty(response, "headersSent", { value: headersSent })
  const error = new Error("reset")
  upstream.emit("error", error)
  if (headersSent) {
    expect(response.destroyed).toBe(true)
    expect(failed).not.toHaveBeenCalled()
  } else {
    expect(response.heads).toEqual([[502, { "Content-Length": "0", Connection: "close" }]])
    expect(response.endings).toBe(1)
    expect(failed).toHaveBeenCalledWith(error)
  }
})

it("bounds HTTP connection setup and cancels its deadline after connecting", () => {
  const { http, upstream, track } = fixture()
  http()
  const socket = new FakeSocket()
  upstream.emit("socket", socket)
  expect(track).toHaveBeenCalledWith(socket)
  socket.onTimeout!()
  expect(upstream.destroyError).toMatchObject({
    message: "Proxy connection timed out",
    code: "ETIMEDOUT"
  })
  socket.emit("connect")
  expect(socket.onTimeout).toBeUndefined()
})

it("cancels an aborted HTTP request", () => {
  const { http, upstream, downstream } = fixture()
  http()
  downstream.emit("aborted")
  expect(upstream.destroyed).toBe(true)
})

it.each([false, true])("cleans up HTTP listeners on close, response finished=%s", (finished) => {
  const { http, upstream, downstream, response } = fixture()
  http()
  Object.defineProperty(response, "writableFinished", { value: finished })
  response.emit("close")
  expect(downstream.listenerCount("aborted")).toBe(0)
  expect(upstream.destroyed).toBe(!finished)
})

it.each([201, undefined])(
  "streams an HTTP response with status %s and propagates body errors",
  (statusCode) => {
    const { http, upstream, client, downstream, response, track } = fixture()
    http()
    const incoming = new FakeIncomingMessage()
    incoming.statusCode = statusCode
    incoming.headers = {
      "set-cookie": ["one=1", "two=2"],
      connection: "close, private",
      private: "omit"
    }
    upstream.emit("response", incoming)
    expect(track).toHaveBeenCalledWith(client)
    expect(downstream.pipes).toEqual([upstream])
    expect(response.heads).toEqual([[statusCode ?? 502, { "set-cookie": ["one=1", "two=2"] }]])
    expect(incoming.pipes).toEqual([response])
    incoming.emit("error", new Error("incomplete body"))
    expect(response.destroyed).toBe(true)
  }
)

it.each(["timeout", "error"])(
  "rejects a WebSocket connection on %s before its handshake",
  (event) => {
    const { upgrade, upstreamSocket, client } = fixture()
    upgrade()
    if (event === "timeout") upstreamSocket.onTimeout!()
    else upstreamSocket.emit("error", new Error("refused"))
    expect(upstreamSocket.destroyed).toBe(true)
    expect(client.endings).toEqual([expect.stringContaining("502 Bad Gateway")])
  }
)

it("preserves early WebSocket bytes and multi-value headers while stripping proxy credentials", () => {
  const { upgrade, upstreamSocket, client, downstream, track } = fixture()
  downstream.headers = {
    upgrade: "websocket",
    cookie: "session=1",
    "x-multi": ["one", "two"],
    "x-absent": undefined,
    "proxy-authorization": "private"
  }
  upgrade(Buffer.from("early frame"))
  upstreamSocket.emit("connect")
  expect(track.mock.calls).toEqual([[client], [upstreamSocket]])
  expect(upstreamSocket.onTimeout).toBeUndefined()
  expect(upstreamSocket.writes).toEqual([
    "GET /page?q=1 HTTP/1.1\r\ncookie: session=1\r\nx-multi: one\r\nx-multi: two\r\nhost: localhost:3000\r\nconnection: Upgrade\r\nupgrade: websocket\r\n\r\n",
    Buffer.from("early frame")
  ])
  expect(client.pipes).toEqual([upstreamSocket])
  expect(upstreamSocket.pipes).toEqual([client])
  upstreamSocket.emit("error", new Error("reset"))
  expect(client.destroyed).toBe(true)
})

it.each([false, true])("handles upstream WebSocket close, readable ended=%s", (ended) => {
  const { upgrade, upstreamSocket, client } = fixture()
  upgrade()
  upstreamSocket.emit("connect")
  Object.defineProperty(upstreamSocket, "readableEnded", { value: ended })
  upstreamSocket.destroy()
  expect(client.destroyed).toBe(!ended)
})

it.each(["close", "error"])("closes a WebSocket upstream when the client emits %s", (event) => {
  const { upgrade, upstreamSocket, client } = fixture()
  upgrade()
  client.emit(event, new Error("client disconnected"))
  expect(upstreamSocket.destroyed).toBe(true)
})

it.each([undefined, "not a URL"])("rejects a malformed forward target %s", (url) => {
  const { downstream, response } = fixture()
  const proxy = new BrowserProxy()
  downstream.url = url
  downstream.headers = { "proxy-authorization": authorization(proxy) }
  proxy.handleHTTP(downstream, response)
  expect(response.heads).toEqual([[400, expect.any(Object)]])
  expect(request).not.toHaveBeenCalled()
  proxy.close()
})

it.each([false, true])(
  "rejects a WebSocket upgrade with invalid authorization=%s",
  (invalidAuth) => {
    const { client, downstream } = fixture()
    const proxy = new BrowserProxy()
    downstream.url = "https://example.com/"
    downstream.headers = { "proxy-authorization": invalidAuth ? "wrong" : authorization(proxy) }
    proxy.handleUpgrade(downstream, client, Buffer.alloc(0))
    expect(client.endings).toEqual([expect.stringContaining(invalidAuth ? "407" : "400")])
    expect(client.endings[0]).toContain(invalidAuth ? "Proxy-Authenticate:" : "Connection: close")
    client.emit("error", new Error("gone"))
    expect(client.destroyed).toBe(true)
    proxy.close()
  }
)

it("uses the default HTTP port and tracks a reused client socket only once", () => {
  const { client, downstream, upstream, upstreamSocket, response } = fixture()
  const proxy = new BrowserProxy()
  downstream.url = "http://example.com/"
  downstream.headers = { "proxy-authorization": authorization(proxy) }
  proxy.handleHTTP(downstream, response)
  proxy.handleHTTP(downstream, response)
  expect(request).toHaveBeenCalledWith(
    expect.objectContaining({ hostname: "example.com", port: 80 })
  )
  expect(client.listenerCount("error")).toBe(1)
  upstream.emit("socket", upstreamSocket)
  client.emit("error", new Error("reset"))
  expect(client.destroyed).toBe(true)
  proxy.close()
  expect(upstreamSocket.destroyed).toBe(true)
})

function authorization(proxy: BrowserProxy) {
  return `Basic ${Buffer.from(`${proxy.session.username}:${proxy.session.password}`).toString("base64")}`
}
