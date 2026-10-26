import { once } from "node:events"
import { createServer, IncomingMessage, request, type Server } from "node:http"
import { createServer as createTCPServer, type Socket } from "node:net"

import { afterEach, describe, expect, it } from "vitest"

import { FakeSocket, listeningPort, tcpSocket } from "../test-support-net.js"
import { BrowserProxy, browserProxyTarget } from "./browser-proxy.js"

describe("browser connection proxy", () => {
  const cleanups: (() => Promise<void> | void)[] = []
  afterEach(async () => {
    const failures: unknown[] = []
    for (const cleanup of cleanups.splice(0).toReversed()) {
      try {
        await cleanup()
      } catch (cause) {
        failures.push(cause)
      }
    }
    if (failures.length > 0) {
      throw new AggregateError(failures, "Cleaning up browser proxy fixtures failed")
    }
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
    return listeningPort(server)
  }

  async function fixture(maximumConnections?: number) {
    const proxy = new BrowserProxy(maximumConnections)
    const server = createServer()
    server.on("connect", (req, socket, head) => proxy.handleConnect(req, tcpSocket(socket), head))
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

  it("remembers why a forwarded HTTP request couldn't reach its site", async () => {
    const closed = createTCPServer()
    const closedPort = await listen(closed)
    await new Promise<void>((resolve) => closed.close(() => resolve()))
    cleanups.pop()
    const proxy = new BrowserProxy()
    cleanups.push(() => proxy.close())
    const server = createServer((req, res) => proxy.handleHTTP(req, res))
    const port = await listen(server)
    const status = await new Promise<number>((resolve, reject) => {
      const req = request(
        {
          host: "127.0.0.1",
          port,
          path: `http://127.0.0.1:${closedPort}/`,
          agent: false,
          headers: {
            "Proxy-Authorization": `Basic ${Buffer.from(`${proxy.session.username}:${proxy.session.password}`).toString("base64")}`
          }
        },
        (res) => {
          res.resume()
          res.on("end", () => resolve(res.statusCode!))
        }
      )
      req.on("error", reject)
      req.end()
    })
    expect(status).toBe(502)
    expect(proxy.failure(`127.0.0.1:${closedPort}`)).toBe("refused")
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

function lifecycleFixture(now?: () => number) {
  const upstream = new FakeSocket()
  const downstream = new FakeSocket()
  const proxy = new BrowserProxy(1, () => upstream, now)
  const auth = `Basic ${Buffer.from(`${proxy.session.username}:${proxy.session.password}`).toString("base64")}`
  const req = new IncomingMessage(downstream)
  req.url = "localhost:3000"
  req.headers = { "proxy-authorization": auth }
  return { proxy, upstream, downstream, req }
}

describe("browser proxy connection lifecycle", () => {
  it("rejects missing credentials", () => {
    const { proxy, downstream, req } = lifecycleFixture()
    req.headers = {}
    proxy.handleConnect(req, downstream, Buffer.alloc(0))
    expect(downstream.endings).toEqual([expect.stringContaining("407")])
    downstream.onTimeout!()
    downstream.emit("error", new Error("closed"))
    expect(downstream.destroyed).toBe(true)
  })

  it.each([
    ["timeout", undefined, "timeout"],
    ["error", "ENOTFOUND", "dns"],
    ["error", "ECONNREFUSED", "refused"],
    ["error", "EHOSTUNREACH", "unreachable"],
    ["error", "EPIPE", "failed"]
  ])("reports a connection %s (%s) without opening a tunnel", (event, code, failure) => {
    let now = 1_000
    const { proxy, upstream, downstream, req } = lifecycleFixture(() => now)
    proxy.handleConnect(req, downstream, Buffer.alloc(0))
    if (event === "timeout") upstream.onTimeout!()
    else upstream.emit("error", Object.assign(new Error("failed"), { code }))
    expect(downstream.endings).toEqual([expect.stringContaining("502")])
    expect(upstream.destroyed).toBe(true)
    expect(proxy.failure("LOCALHOST:3000")).toBe(failure)
    expect(proxy.failure("localhost:3001")).toBeUndefined()
    now += 60_001
    expect(proxy.failure("localhost:3000")).toBeUndefined()
    proxy.close()
  })

  it("remembers only the most recent failing targets", () => {
    let upstream = new FakeSocket()
    const proxy = new BrowserProxy(1_000, () => (upstream = new FakeSocket()))
    const authorization = `Basic ${Buffer.from(`${proxy.session.username}:${proxy.session.password}`).toString("base64")}`
    for (let port = 1; port <= 129; port++) {
      const req = new IncomingMessage(new FakeSocket())
      req.url = `example.com:${port}`
      req.headers = { "proxy-authorization": authorization }
      proxy.handleConnect(req, new FakeSocket(), Buffer.alloc(0))
      upstream.emit("error", Object.assign(new Error("not found"), { code: "ENOTFOUND" }))
    }
    expect(proxy.failure("example.com:1")).toBeUndefined()
    expect(proxy.failure("example.com:2")).toBe("dns")
    expect(proxy.failure("example.com:129")).toBe("dns")
    proxy.close()
  })

  it("forwards early tunnel bytes and tears down both ends on an upstream failure", () => {
    const { proxy, upstream, downstream, req } = lifecycleFixture()
    proxy.handleConnect(req, downstream, Buffer.from("early data"))
    upstream.emit("connect")
    expect(upstream.writes).toEqual([Buffer.from("early data")])
    expect(downstream.writes).toEqual([expect.stringContaining("200 Connection Established")])
    upstream.emit("error", new Error("reset"))
    expect(downstream.destroyed).toBe(true)
    proxy.close()
  })

  it("closes the upstream when the browser disconnects", () => {
    const { proxy, upstream, downstream, req } = lifecycleFixture()
    proxy.handleConnect(req, downstream, Buffer.alloc(0))
    downstream.emit("error", new Error("client reset"))
    expect(upstream.destroyed).toBe(true)
    proxy.close()
  })
})
