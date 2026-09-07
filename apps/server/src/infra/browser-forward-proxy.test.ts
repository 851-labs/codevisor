import { once } from "node:events"
import { createServer, request, type Server, type ClientRequest } from "node:http"
import { type AddressInfo, type Socket } from "node:net"
import { afterEach, expect, it } from "vitest"
import { WebSocket, WebSocketServer } from "ws"
import { BrowserProxy } from "./browser-proxy.js"
import { isBrowserProxyRequest } from "./browser-forward-proxy.js"

const cleanups: (() => void | Promise<void>)[] = []
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).toReversed()) await cleanup()
})
async function listen(server: Server) {
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
  const server = createServer((req, res) => {
    if (isBrowserProxyRequest(req)) proxy.handleHTTP(req, res)
    else res.writeHead(200).end("control API")
  })
  server.on("upgrade", (req, socket, head) => proxy.handleUpgrade(req, socket as Socket, head))
  const port = await listen(server)
  cleanups.push(() => proxy.close())
  const auth = `Basic ${Buffer.from(`${proxy.session.username}:${proxy.session.password}`).toString("base64")}`
  const send = (
    url: string,
    options: {
      auth?: string
      method?: string
      headers?: Record<string, string>
      body?: string
    } = {}
  ) =>
    new Promise<{ status: number; body: string; headers: Record<string, unknown> }>(
      (resolve, reject) => {
        const req = request(
          {
            host: "127.0.0.1",
            port,
            path: url,
            method: options.method ?? "GET",
            agent: false,
            headers: { "proxy-authorization": options.auth ?? auth, ...options.headers }
          },
          (res) => {
            let body = ""
            res.on("data", (chunk) => {
              body += String(chunk)
            })
            res.on("error", reject)
            res.on("end", () => resolve({ status: res.statusCode!, body, headers: res.headers }))
          }
        )
        req.on("error", reject)
        req.end(options.body)
      }
    )
  return { proxy, port, auth, send }
}

it("forwards original origins, credentials, bodies and response cookies without proxy credentials", async () => {
  const upstream = createServer((req, res) => {
    let body = ""
    req.on("data", (chunk) => {
      body += String(chunk)
    })
    req.on("end", () =>
      res
        .writeHead(201, {
          "set-cookie": ["session=local; HttpOnly", "theme=dark"],
          "access-control-allow-origin": req.headers.origin!,
          connection: "close, x-private-hop",
          "x-private-hop": "omit"
        })
        .end(JSON.stringify({ method: req.method, url: req.url, headers: req.headers, body }))
    )
  })
  const upstreamPort = await listen(upstream)
  const { send } = await fixture()
  const response = await send(`http://localhost:${upstreamPort}/api?q=1`, {
    method: "POST",
    body: "hello",
    headers: {
      origin: "http://localhost:3000",
      cookie: "session=local",
      authorization: "Bearer website",
      connection: "close, x-private-hop",
      "x-private-hop": "omit"
    }
  })
  expect(response.status).toBe(201)
  expect(JSON.parse(response.body)).toMatchObject({
    method: "POST",
    url: "/api?q=1",
    body: "hello",
    headers: {
      host: `localhost:${upstreamPort}`,
      origin: "http://localhost:3000",
      cookie: "session=local",
      authorization: "Bearer website"
    }
  })
  expect(JSON.parse(response.body).headers["proxy-authorization"]).toBeUndefined()
  expect(JSON.parse(response.body).headers["x-private-hop"]).toBeUndefined()
  expect(response.headers["x-private-hop"]).toBeUndefined()
  expect(response.headers["set-cookie"]).toEqual(["session=local; HttpOnly", "theme=dark"])
  expect(response.headers["access-control-allow-origin"]).toBe("http://localhost:3000")
})

it("keeps absolute URLs out of the control API and rejects forbidden targets", async () => {
  const { send, port } = await fixture()
  const denied = await send("http://example.com/v1/health", { auth: "wrong" })
  expect(denied.status).toBe(407)
  expect(denied.headers["proxy-authenticate"]).toContain("Basic")
  expect(denied.body).not.toContain("control API")
  expect((await send(`http://localhost:${port}/v1/health`)).status).toBe(403)
  expect((await send(`http://dns-alias.example:${port}/v1/health`)).status).toBe(403)
  expect((await send("http://user:password@example.com/")).status).toBe(400)
  expect((await send("https://example.com/")).status).toBe(400)
  expect((await send("http://localhost:0/")).status).toBe(400)
})

it("rejects new HTTP requests at capacity and after shutdown", async () => {
  const limited = await fixture(0)
  expect((await limited.send("http://localhost:3000/")).status).toBe(503)
  const closed = await fixture()
  closed.proxy.close()
  expect((await closed.send("http://localhost:3000/")).status).toBe(503)
})

it("forwards Chromium's absolute-form WebSocket upgrade with the original host and origin", async () => {
  const upstream = createServer()
  const ws = new WebSocketServer({ server: upstream })
  ws.on("connection", (client, req) => {
    client.on("message", (data) =>
      client.send(JSON.stringify({ data: String(data), headers: req.headers }))
    )
  })
  const target = await listen(upstream)
  cleanups.push(() => {
    for (const client of ws.clients) client.terminate()
    ws.close()
  })
  const { port, auth } = await fixture()
  const client = new WebSocket(`ws://127.0.0.1:${port}`, {
    finishRequest: (req) => {
      // ws passes ClientRequest here; @types/ws currently calls it IncomingMessage.
      const outgoing = req as unknown as ClientRequest
      outgoing.path = `http://localhost:${target}/hmr`
      outgoing.end()
    },
    origin: "http://localhost:3000",
    headers: { "Proxy-Authorization": auth }
  })
  cleanups.push(() => client.terminate())
  await once(client, "open")
  const received = once(client, "message")
  client.send("hot reload")
  const result = JSON.parse(String((await received)[0]))
  expect(result).toMatchObject({
    data: "hot reload",
    headers: { host: `localhost:${target}`, origin: "http://localhost:3000" }
  })
  expect(result.headers["proxy-authorization"]).toBeUndefined()
})
