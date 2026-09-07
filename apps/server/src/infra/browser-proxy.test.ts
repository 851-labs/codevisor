import { EventEmitter, once } from "node:events"
import { createServer, request, type Server, type IncomingMessage } from "node:http"
import { createServer as createTCPServer, type AddressInfo, type Socket } from "node:net"
import { afterEach, describe, expect, it } from "vitest"
import { BrowserProxy, browserProxyTarget } from "./browser-proxy.js"

describe("browser connection proxy", () => {
  const cleanups: (() => Promise<void> | void)[] = []
  afterEach(async () => {
    await cleanups
      .splice(0)
      .toReversed()
      .reduce(async (previous, cleanup) => {
        await previous
        await cleanup()
      }, Promise.resolve())
  })

  async function listen(server: Server | ReturnType<typeof createTCPServer>) {
    server.listen(0, "127.0.0.1")
    await once(server, "listening")
    cleanups.push(
      () =>
        new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve()))
        )
    )
    return (server.address() as AddressInfo).port
  }

  async function fixture(maximumConnections?: number) {
    const proxy = new BrowserProxy(maximumConnections)
    const server = createServer()
    server.on("connect", (req, socket, head) => proxy.handleConnect(req, socket as Socket, head))
    const port = await listen(server)
    cleanups.push(() => proxy.close())
    const authorization = `Basic ${Buffer.from(`${proxy.session.username}:${proxy.session.password}`).toString("base64")}`
    const tunnel = (target: string, credential: string | undefined = authorization) =>
      new Promise<{ socket: Socket; status: number }>((resolve, reject) => {
        const req = request({
          host: "127.0.0.1",
          port,
          method: "CONNECT",
          path: target,
          headers: credential === undefined ? {} : { "Proxy-Authorization": credential }
        })
        req.on("error", reject)
        req.on("connect", (response, socket) => {
          cleanups.push(() => {
            socket.destroy()
          })
          resolve({ socket, status: response.statusCode! })
        })
        req.end()
      })
    return { proxy, port, tunnel }
  }

  it.each([
    undefined,
    "",
    "localhost",
    "user:pass@host:80",
    "host:0",
    "host:65536",
    "host:999999",
    "host:80/path",
    "host:80?x",
    "host:80\r\nInjected: yes"
  ])("rejects malformed authority %s", (authority) => {
    expect(browserProxyTarget(authority)).toBeUndefined()
  })

  it("resolves localhost on the machine and preserves other authorities", () => {
    expect(browserProxyTarget("LOCALHOST:3000")).toEqual({ host: "127.0.0.1", port: 3000 })
    expect(browserProxyTarget("app.localhost:3001")).toEqual({ host: "127.0.0.1", port: 3001 })
    expect(browserProxyTarget("[::1]:3000")).toEqual({ host: "::1", port: 3000 })
    expect(browserProxyTarget("proxy.localhost:3000")).toEqual({
      host: "127.0.0.1",
      port: 3000
    })
    expect(browserProxyTarget("ipv4-127-0-0-2.proxy.localhost:3000")).toEqual({
      host: "127.0.0.2",
      port: 3000
    })
    expect(browserProxyTarget("ipv4-127-0-0-256.proxy.localhost:3000")).toBeUndefined()
    expect(browserProxyTarget("ipv6.proxy.localhost:3000")).toEqual({ host: "::1", port: 3000 })
    expect(browserProxyTarget("example.com:443")).toEqual({ host: "example.com", port: 443 })
  })

  it("requires its own capability even from loopback and rejects malformed or forbidden targets", async () => {
    const { tunnel, port, proxy } = await fixture()
    expect((await tunnel("localhost:3000", "")).status).toBe(407)
    expect(
      (
        await tunnel(
          "localhost:3000",
          "Basic " +
            "x".repeat(
              Buffer.from(`${proxy.session.username}:${proxy.session.password}`).toString("base64")
                .length
            )
        )
      ).status
    ).toBe(407)
    expect((await tunnel("localhost:0")).status).toBe(400)
    expect((await tunnel(`localhost:${port}`)).status).toBe(403)
    expect((await tunnel(`dns-alias.example:${port}`)).status).toBe(403)
  })

  it("refuses connections after shutdown or when at capacity", async () => {
    const limited = await fixture(0)
    expect((await limited.tunnel("localhost:3000")).status).toBe(503)
    const closed = await fixture()
    closed.proxy.close()
    expect((await closed.tunnel("localhost:3000")).status).toBe(503)
  })

  it("streams requests and responses without changing cookies, origins, or website authorization", async () => {
    const upstream = createServer((req, res) => {
      let body = ""
      req.on("data", (chunk) => {
        body += String(chunk)
      })
      req.on("end", () => {
        res.writeHead(200, { "Set-Cookie": "session=website; HttpOnly" })
        res.end(JSON.stringify({ headers: req.headers, url: req.url, body }))
      })
    })
    const port = await listen(upstream)
    const { tunnel } = await fixture()
    const { status, socket } = await tunnel(`localhost:${port}`)
    expect(status).toBe(200)
    const response = new Promise<{ body: string; cookie: string[] | undefined }>(
      (resolve, reject) => {
        const req = request(
          {
            host: "localhost",
            port,
            path: "/api?query=value",
            method: "POST",
            createConnection: () => socket,
            headers: {
              Origin: `http://localhost:${port}`,
              Cookie: "session=website",
              Authorization: "Bearer website-token"
            }
          },
          (res) => {
            let body = ""
            res.on("data", (chunk) => {
              body += String(chunk)
            })
            res.on("end", () => resolve({ body, cookie: res.headers["set-cookie"] }))
            res.on("error", reject)
          }
        )
        req.on("error", reject)
        req.end("request body")
      }
    )
    const result = await response
    expect(JSON.parse(result.body)).toMatchObject({
      headers: {
        host: `localhost:${port}`,
        origin: `http://localhost:${port}`,
        cookie: "session=website",
        authorization: "Bearer website-token"
      },
      url: "/api?query=value",
      body: "request body"
    })
    expect(JSON.parse(result.body).headers["proxy-authorization"]).toBeUndefined()
    expect(result.cookie).toEqual(["session=website; HttpOnly"])
  })

  it("carries upgraded WebSockets as opaque bytes", async () => {
    const { WebSocketServer, WebSocket } = await import("ws")
    const upstream = createServer()
    const ws = new WebSocketServer({ server: upstream })
    ws.on("connection", (client) => client.on("message", (data) => client.send(data)))
    const port = await listen(upstream)
    cleanups.push(() => {
      for (const client of ws.clients) client.terminate()
      ws.close()
    })
    const { tunnel } = await fixture()
    const { socket } = await tunnel(`localhost:${port}`)
    const client = new WebSocket(`ws://localhost:${port}/hmr`, { createConnection: () => socket })
    cleanups.push(() => client.terminate())
    await once(client, "open")
    const received = once(client, "message")
    client.send("hot reload")
    expect(String((await received)[0])).toBe("hot reload")
  })
})

// The connection lifecycle is deterministic here: explicitly deliver connect,
// timeout, and socket failures rather than relying on OS error timing.
describe("browser proxy connection lifecycle", () => {
  class FakeSocket extends EventEmitter {
    destroyed = false
    writes: string[] = []
    timeout: (() => void) | undefined
    localPort = 49000
    setTimeout(_ms: number, callback?: () => void) {
      if (callback) this.timeout = callback
      return this
    }
    setNoDelay() {
      return this
    }
    write(data: string | Buffer) {
      this.writes.push(String(data))
      return true
    }
    end(data: string) {
      this.write(data)
      return this
    }
    pipe() {
      return this
    }
    destroy() {
      if (!this.destroyed) {
        this.destroyed = true
        this.emit("close")
      }
      return this
    }
  }

  function fixture() {
    const upstream = new FakeSocket()
    const downstream = new FakeSocket()
    const proxy = new BrowserProxy(1, () => upstream as unknown as Socket)
    const auth = `Basic ${Buffer.from(`${proxy.session.username}:${proxy.session.password}`).toString("base64")}`
    const req = {
      url: "localhost:3000",
      socket: downstream,
      headers: { "proxy-authorization": auth }
    } as unknown as IncomingMessage
    return { proxy, upstream, downstream, req }
  }

  it("rejects missing credentials", () => {
    const { proxy, downstream, req } = fixture()
    req.headers = {}
    proxy.handleConnect(req, downstream as unknown as Socket, Buffer.alloc(0))
    expect(downstream.writes[0]).toContain("407")
    downstream.timeout!()
    downstream.emit("error", new Error("closed"))
    expect(downstream.destroyed).toBe(true)
  })

  it.each(["timeout", "error"])("reports a connection %s without opening a tunnel", (event) => {
    const { proxy, upstream, downstream, req } = fixture()
    proxy.handleConnect(req, downstream as unknown as Socket, Buffer.alloc(0))
    if (event === "timeout") upstream.timeout!()
    else upstream.emit("error", new Error("refused"))
    expect(downstream.writes[0]).toContain("502")
    expect(upstream.destroyed).toBe(true)
    proxy.close()
  })

  it("forwards early tunnel bytes and tears down both ends on an upstream failure", () => {
    const { proxy, upstream, downstream, req } = fixture()
    proxy.handleConnect(req, downstream as unknown as Socket, Buffer.from("early data"))
    upstream.emit("connect")
    expect(upstream.writes).toEqual(["early data"])
    expect(downstream.writes[0]).toContain("200 Connection Established")
    upstream.emit("error", new Error("reset"))
    expect(downstream.destroyed).toBe(true)
    proxy.close()
  })

  it("closes the upstream when the browser disconnects", () => {
    const { proxy, upstream, downstream, req } = fixture()
    proxy.handleConnect(req, downstream as unknown as Socket, Buffer.alloc(0))
    downstream.emit("error", new Error("client reset"))
    expect(upstream.destroyed).toBe(true)
    proxy.close()
  })
})
