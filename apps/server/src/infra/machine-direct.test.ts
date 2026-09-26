import { createServer, type IncomingMessage, type ServerResponse } from "node:http"
import type { AddressInfo } from "node:net"

import { afterEach, describe, expect, it } from "vitest"

import { DirectPathError, postDirect, postGatewayInvoke, probeDirect } from "./machine-direct.js"

/// Real loopback sockets: the phase a failure is reported in depends on
/// actual connect/write/response events, which is the behavior under test.

const servers: ReturnType<typeof createServer>[] = []
afterEach(async () => {
  await Promise.all(
    servers.splice(0).map(
      (server) =>
        new Promise<void>((resolve) => {
          server.closeAllConnections()
          server.close(() => resolve())
        })
    )
  )
})

const listen = async (
  handler: (request: IncomingMessage, response: ServerResponse, body: string) => void
): Promise<string> => {
  const server = createServer((request, response) => {
    let body = ""
    request.on("data", (chunk: Buffer) => (body += chunk.toString("utf8")))
    request.on("end", () => handler(request, response, body))
  })
  servers.push(server)
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`
}

/// A port nothing listens on: bind, note the port, release it.
const closedPort = async (): Promise<number> => {
  const server = createServer()
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const { port } = server.address() as AddressInfo
  await new Promise<void>((resolve) => server.close(() => resolve()))
  return port
}

const rejection = async (promise: Promise<unknown>): Promise<unknown> =>
  promise.then(
    () => undefined,
    (cause: unknown) => cause
  )

describe("direct machine path", () => {
  it("posts the call with the route's bearer token and returns the answer", async () => {
    const seen: unknown[] = []
    const url = await listen((request, response, body) => {
      seen.push({ auth: request.headers.authorization, path: request.url, body })
      response.writeHead(200, { "content-type": "application/json" })
      response.end('{"result":1}')
    })
    expect(await postGatewayInvoke({ url, token: "secret" }, '{"a":1}')).toEqual({
      status: 200,
      body: '{"result":1}'
    })
    await postGatewayInvoke({ url }, "{}", new AbortController().signal)
    expect(seen).toEqual([
      { auth: "Bearer secret", path: "/v1/gateway/invoke", body: '{"a":1}' },
      { auth: undefined, path: "/v1/gateway/invoke", body: "{}" }
    ])
  })

  it.each(["http", "https"])("reports a refused %s connection as before-send", async (scheme) => {
    const port = await closedPort()
    const error = await rejection(postDirect({ url: `${scheme}://127.0.0.1:${port}` }, "/x", "{}"))
    expect(error).toBeInstanceOf(DirectPathError)
    expect((error as DirectPathError).phase).toBe("before-send")
  })

  it("reports a connection that times out before connecting as before-send", async () => {
    const url = await listen((_request, response) => response.end("{}"))
    let fire!: () => void
    const pending = postDirect({ url }, "/x", "{}", {
      scheduleTimeout: (callback) => {
        fire = callback
        return () => undefined
      }
    })
    // The connect needs an event-loop turn; the deadline fires first.
    fire()
    expect(await rejection(pending)).toMatchObject({
      phase: "before-send",
      message: "timed out connecting"
    })
  })

  it("reports a peer that drops the connection after receiving the call as in-flight", async () => {
    const url = await listen((request) => request.socket.destroy())
    expect(await rejection(postDirect({ url }, "/x", "{}"))).toMatchObject({ phase: "in-flight" })
  })

  it("reports a peer that dies mid-answer as in-flight", async () => {
    const url = await listen((_request, response) => {
      response.writeHead(200, { "content-length": "100" })
      response.write("partial", () => response.socket?.destroy())
    })
    expect(await rejection(postDirect({ url }, "/x", "{}"))).toMatchObject({ phase: "in-flight" })
  })

  it("cancels the request on abort with the caller's reason", async () => {
    let received!: () => void
    const arrived = new Promise<void>((resolve) => {
      received = resolve
    })
    const url = await listen(() => received())
    const controller = new AbortController()
    const reason = new Error("caller aborted")
    const pending = postDirect({ url }, "/x", "{}", { signal: controller.signal })
    await arrived
    controller.abort(reason)
    expect(await rejection(pending)).toBe(reason)
    expect(await rejection(postDirect({ url }, "/x", "{}", { signal: controller.signal }))).toBe(
      reason
    )
  })

  it("probes reachability and platform through the discovery manifest", async () => {
    const url = await listen((request, response) => {
      response.writeHead(request.url === "/v1/discovery" ? 200 : 404)
      response.end(JSON.stringify({ platform: "linux" }))
    })
    const bare = await listen((_request, response) => {
      response.writeHead(200)
      response.end("not json")
    })
    const missing = await listen((_request, response) => {
      response.writeHead(404)
      response.end()
    })
    expect(await probeDirect({ url })).toEqual({ online: true, os: "linux" })
    expect(await probeDirect({ url: bare })).toEqual({ online: true })
    expect(await probeDirect({ url: missing })).toEqual({ online: false })
    expect(await probeDirect({ url: `http://127.0.0.1:${await closedPort()}` })).toEqual({
      online: false
    })
  })
})
