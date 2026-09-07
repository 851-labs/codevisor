import { EventEmitter } from "node:events"
import { request, type IncomingMessage, type ServerResponse } from "node:http"
import { connect, type Socket } from "node:net"
import { afterEach, expect, it, vi } from "vitest"
import { forwardBrowserHTTP, forwardBrowserUpgrade } from "./browser-forward-proxy.js"
import { BrowserProxy } from "./browser-proxy.js"

vi.mock("node:http", () => ({ request: vi.fn() }))
vi.mock("node:net", () => ({ connect: vi.fn() }))
afterEach(() => vi.clearAllMocks())

// Drive socket lifecycle events explicitly, including failures that are otherwise
// dependent on OS timing. No listening ports or connection deadlines are needed.
class Endpoint extends EventEmitter {
  headers: IncomingMessage["headers"] = {}
  method = "GET"
  url: string | undefined = "http://localhost:3000/page?q=1"
  localPort = 49000
  statusCode: number | undefined = 200
  headersSent = false
  writableFinished = false
  readableEnded = false
  destroyed = false
  socket = this
  timeout: (() => void) | undefined
  write = vi.fn((_data: string | Buffer) => true)
  end = vi.fn((_data?: string) => this)
  writeHead = vi.fn((_status: number, _headers?: IncomingMessage["headers"]) => this)
  pipe = vi.fn((_destination: unknown) => this)
  setNoDelay = vi.fn(() => this)
  setTimeout(milliseconds: number, callback?: () => void) {
    this.timeout = milliseconds === 0 ? undefined : callback
    return this
  }
  destroy = vi.fn((_error?: Error) => {
    if (!this.destroyed) {
      this.destroyed = true
      this.emit("close")
    }
    return this
  })
  asSocket() {
    return this as unknown as Socket
  }
  asRequest() {
    return this as unknown as IncomingMessage
  }
  asResponse() {
    return this as unknown as ServerResponse
  }
}

function fixture() {
  const upstream = new Endpoint()
  const downstream = new Endpoint()
  const response = new Endpoint()
  const track = vi.fn()
  vi.mocked(request).mockReturnValue(upstream as unknown as ReturnType<typeof request>)
  vi.mocked(connect).mockReturnValue(upstream.asSocket())
  const target = { host: "127.0.0.1", port: 3000, url: new URL(downstream.url!) }
  return {
    upstream,
    downstream,
    response,
    track,
    http: () => forwardBrowserHTTP(downstream.asRequest(), response.asResponse(), target, track),
    upgrade: (head = Buffer.alloc(0)) =>
      forwardBrowserUpgrade(downstream.asRequest(), downstream.asSocket(), head, target, track)
  }
}

it.each([false, true])("handles HTTP upstream failure after headers=%s", (headersSent) => {
  const { http, upstream, response } = fixture()
  http()
  response.headersSent = headersSent
  upstream.emit("error", new Error("reset"))
  if (headersSent) expect(response.destroyed).toBe(true)
  else {
    expect(response.writeHead).toHaveBeenCalledWith(502, {
      "Content-Length": "0",
      Connection: "close"
    })
    expect(response.end).toHaveBeenCalledOnce()
  }
})

it("bounds HTTP connection setup and cancels its deadline after connecting", () => {
  const { http, upstream, track } = fixture()
  http()
  const socket = new Endpoint()
  upstream.emit("socket", socket)
  expect(track).toHaveBeenCalledWith(socket)
  socket.timeout!()
  expect(upstream.destroy).toHaveBeenCalledWith(new Error("Proxy connection timed out"))
  socket.emit("connect")
  expect(socket.timeout).toBeUndefined()
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
  response.writableFinished = finished
  response.emit("close")
  expect(downstream.listenerCount("aborted")).toBe(0)
  expect(upstream.destroyed).toBe(!finished)
})

it.each([201, undefined])(
  "streams an HTTP response with status %s and propagates body errors",
  (statusCode) => {
    const { http, upstream, downstream, response, track } = fixture()
    http()
    const incoming = new Endpoint()
    incoming.statusCode = statusCode
    incoming.headers = {
      "set-cookie": ["one=1", "two=2"],
      connection: "close, private",
      private: "omit"
    }
    upstream.emit("response", incoming)
    expect(track).toHaveBeenCalledWith(downstream)
    expect(downstream.pipe).toHaveBeenCalledWith(upstream)
    expect(response.writeHead).toHaveBeenCalledWith(statusCode ?? 502, {
      "set-cookie": ["one=1", "two=2"]
    })
    expect(incoming.pipe).toHaveBeenCalledWith(response)
    incoming.emit("error", new Error("incomplete body"))
    expect(response.destroyed).toBe(true)
  }
)

it.each(["timeout", "error"])(
  "rejects a WebSocket connection on %s before its handshake",
  (event) => {
    const { upgrade, upstream, downstream } = fixture()
    upgrade()
    if (event === "timeout") upstream.timeout!()
    else upstream.emit("error", new Error("refused"))
    expect(upstream.destroyed).toBe(true)
    expect(downstream.end).toHaveBeenCalledWith(expect.stringContaining("502 Bad Gateway"))
  }
)

it("preserves early WebSocket bytes and multi-value headers while stripping proxy credentials", () => {
  const { upgrade, upstream, downstream, track } = fixture()
  downstream.headers = {
    upgrade: "websocket",
    cookie: "session=1",
    "x-multi": ["one", "two"],
    "x-absent": undefined,
    "proxy-authorization": "private"
  }
  upgrade(Buffer.from("early frame"))
  upstream.emit("connect")
  expect(track.mock.calls).toEqual([[downstream], [upstream]])
  expect(upstream.timeout).toBeUndefined()
  expect(upstream.write.mock.calls).toEqual([
    [
      "GET /page?q=1 HTTP/1.1\r\ncookie: session=1\r\nx-multi: one\r\nx-multi: two\r\nhost: localhost:3000\r\nconnection: Upgrade\r\nupgrade: websocket\r\n\r\n"
    ],
    [Buffer.from("early frame")]
  ])
  expect(downstream.pipe).toHaveBeenCalledWith(upstream)
  expect(upstream.pipe).toHaveBeenCalledWith(downstream)
  upstream.emit("error", new Error("reset"))
  expect(downstream.destroyed).toBe(true)
})

it.each([false, true])("handles upstream WebSocket close, readable ended=%s", (ended) => {
  const { upgrade, upstream, downstream } = fixture()
  upgrade()
  upstream.emit("connect")
  upstream.readableEnded = ended
  upstream.destroy()
  expect(downstream.destroyed).toBe(!ended)
})

it.each(["close", "error"])("closes a WebSocket upstream when the client emits %s", (event) => {
  const { upgrade, upstream, downstream } = fixture()
  upgrade()
  downstream.emit(event, new Error("client disconnected"))
  expect(upstream.destroyed).toBe(true)
})

it.each([undefined, "not a URL"])("rejects a malformed forward target %s", (url) => {
  const { downstream, response } = fixture()
  const proxy = new BrowserProxy()
  downstream.url = url
  downstream.headers = { "proxy-authorization": authorization(proxy) }
  proxy.handleHTTP(downstream.asRequest(), response.asResponse())
  expect(response.writeHead).toHaveBeenCalledWith(400, expect.any(Object))
  expect(request).not.toHaveBeenCalled()
  proxy.close()
})

it.each([false, true])(
  "rejects a WebSocket upgrade with invalid authorization=%s",
  (invalidAuth) => {
    const { downstream } = fixture()
    const proxy = new BrowserProxy()
    downstream.url = "https://example.com/"
    downstream.headers = { "proxy-authorization": invalidAuth ? "wrong" : authorization(proxy) }
    proxy.handleUpgrade(downstream.asRequest(), downstream.asSocket(), Buffer.alloc(0))
    expect(downstream.end).toHaveBeenCalledWith(
      expect.stringContaining(invalidAuth ? "407" : "400")
    )
    expect(downstream.end.mock.calls[0]![0]).toContain(
      invalidAuth ? "Proxy-Authenticate:" : "Connection: close"
    )
    downstream.emit("error", new Error("gone"))
    expect(downstream.destroyed).toBe(true)
    proxy.close()
  }
)

it("uses the default HTTP port and tracks a reused client socket only once", () => {
  const { downstream, upstream, response } = fixture()
  const proxy = new BrowserProxy()
  downstream.url = "http://example.com/"
  downstream.headers = { "proxy-authorization": authorization(proxy) }
  proxy.handleHTTP(downstream.asRequest(), response.asResponse())
  proxy.handleHTTP(downstream.asRequest(), response.asResponse())
  expect(request).toHaveBeenCalledWith(
    expect.objectContaining({ hostname: "example.com", port: 80 })
  )
  expect(downstream.listenerCount("error")).toBe(1)
  upstream.emit("socket", upstream)
  downstream.emit("error", new Error("reset"))
  expect(downstream.destroyed).toBe(true)
  proxy.close()
  expect(upstream.destroyed).toBe(true)
})

function authorization(proxy: BrowserProxy) {
  return `Basic ${Buffer.from(`${proxy.session.username}:${proxy.session.password}`).toString("base64")}`
}
