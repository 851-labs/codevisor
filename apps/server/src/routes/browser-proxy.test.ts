import { request, createServer } from "node:http"
import { once } from "node:events"
import { handleRequest } from "../server-router.js"
import { defaultServerConfig, makeEventFanout, type RouteState } from "../server.js"
import { idleRestartCoordinator, makeServices, run } from "../test-support.js"
import { describe, expect, it } from "vitest"
import { jsonRequest, start } from "../test-support.js"

const proxyRequest = (port: number, upgrade = false) =>
  new Promise<number>((resolve, reject) => {
    const req = request(
      {
        host: "127.0.0.1",
        port,
        path: "http://example.com/v1/health",
        agent: false,
        headers: upgrade ? { Connection: "Upgrade", Upgrade: "websocket" } : {}
      },
      (res) => {
        res.resume()
        res.on("end", () => resolve(res.statusCode!))
      }
    )
    req.on("error", reject)
    req.end()
  })

describe("browser proxy session", () => {
  it("routes CONNECT through the real server listener and checks normal API authorization", async () => {
    const { server } = await start({ requireBearerToken: true, allowLocalhostWithoutAuth: false })
    expect(
      (await jsonRequest(server, "/v1/browser/proxy-session", { method: "POST" })).status
    ).toBe(401)
    const status = await new Promise<number>((resolve, reject) => {
      const req = request({
        host: "127.0.0.1",
        port: server.port,
        method: "CONNECT",
        path: "localhost:3000"
      })
      req.on("error", reject)
      req.on("connect", (res, socket) => {
        socket.destroy()
        resolve(res.statusCode!)
      })
      req.end()
    })
    expect(status).toBe(407)
  })

  it.each([false, true])(
    "routes absolute-form requests to the proxy, upgrade=%s",
    async (upgrade) => {
      const { server } = await start()
      expect(await proxyRequest(server.port, upgrade)).toBe(407)
    }
  )

  it("reports an unavailable proxy in a router without that service", async () => {
    const { services } = await makeServices()
    const fanout = await run(makeEventFanout)
    const state: RouteState = {
      activePromptSessions: new Set(),
      activeTurnSessions: new Set(),
      gatedSessions: new Map(),
      pendingPromptActions: new Set(),
      pendingSessionCreates: new Map(),
      turnHeldSessions: new Set(),
      updateSignature: {},
      restartHeldSessions: new Set(),
      restart: idleRestartCoordinator()
    }
    const http = createServer((req, res) => {
      void handleRequest(services, defaultServerConfig(), fanout, state, req, res)
    })
    http.listen(0, "127.0.0.1")
    await once(http, "listening")
    try {
      const address = http.address()
      if (address === null || typeof address === "string") throw new Error("No listener")
      const response = await fetch(`http://127.0.0.1:${address.port}/v1/browser/proxy-session`, {
        method: "POST"
      })
      expect(response.status).toBe(501)
      await response.text()
      expect(await proxyRequest(address.port)).toBe(501)
    } finally {
      await new Promise<void>((resolve) => http.close(() => resolve()))
    }
  })

  it("issues a separate process-scoped credential and refuses website callers", async () => {
    const { server } = await start()
    const first = await jsonRequest(server, "/v1/browser/proxy-session", { method: "POST" })
    expect(first.status).toBe(201)
    expect(first.body).toMatchObject({
      username: "codevisor-browser",
      password: expect.any(String)
    })
    expect(
      (await jsonRequest(server, "/v1/browser/proxy-session", { method: "POST" })).body
    ).toEqual(first.body)
    expect(
      (
        await jsonRequest(server, "/v1/browser/proxy-session", {
          method: "POST",
          headers: { Origin: "http://localhost:3000" }
        })
      ).status
    ).toBe(403)
    const response = await fetch(`${server.url}/v1/browser/proxy-session`, { method: "POST" })
    expect(response.headers.get("cache-control")).toBe("no-store")
  })
})
