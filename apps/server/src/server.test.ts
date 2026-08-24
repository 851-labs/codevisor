import { Effect } from "effect"
import { createServer } from "node:http"
import { WebSocket } from "ws"
import { describe, expect, it, vi } from "vitest"
import {
  defaultDatabasePath,
  defaultServerConfig,
  makeEventFanout,
  startCodevisorServer
} from "./server.js"
import type { CodevisorServerServices } from "./server.js"
import { readTailnetPeers } from "./infra/tailnet.js"
import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  start,
  startWithApp,
  waitFor
} from "./test-support.js"

// The tailnet route shells out to the machine's Tailscale CLI; mock the
// reader so the route's two shapes are deterministic on any test machine.
vi.mock("./infra/tailnet.js", () => ({ readTailnetPeers: vi.fn() }))

describe("@codevisor/server", () => {
  it("holds host sleep only while at least one session is active", async () => {
    const { services } = await makeServices("server-a")
    const fanout = await run(makeEventFanout)
    const updates: Array<readonly [string, boolean]> = []
    const sessionActivity = {
      update: vi.fn((sessionId: string, active: boolean) => {
        updates.push([sessionId, active])
      }),
      stop: vi.fn()
    }
    const server = await startWithApp(services, fanout, { sessionActivity })
    const event = (subjectId: string, sidebarState: "inProgress" | "idle") => ({
      id: 1,
      serverId: "server-a",
      kind: "session.attention.updated" as const,
      subjectId,
      createdAt: new Date().toISOString(),
      payload: { sidebarState }
    })

    await run(fanout.publish(event("session-a", "inProgress")))
    await run(fanout.publish(event("session-a", "inProgress")))
    await run(fanout.publish(event("session-b", "inProgress")))
    await run(fanout.publish({ ...event("ignored-kind", "idle"), kind: "session.updated" }))
    await run(fanout.publish({ ...event("invalid-payload", "idle"), payload: null }))
    await run(fanout.publish(event("session-a", "idle")))
    await run(fanout.publish(event("session-b", "idle")))
    await run(fanout.publish(event("session-b", "idle")))

    expect(updates).toEqual([
      ["session-a", true],
      ["session-b", true],
      ["session-a", false],
      ["session-b", false]
    ])
    await run(server.close)
    expect(sessionActivity.stop).toHaveBeenCalledOnce()
  })

  it("gates HTTP and websocket clients until startup recovery finishes", async () => {
    const { services } = await makeServices("server-a")
    const reservation = createServer()
    await new Promise<void>((resolve) => reservation.listen(0, "127.0.0.1", resolve))
    const address = reservation.address()
    const port = typeof address === "object" && address !== null ? address.port : 0
    await new Promise<void>((resolve) => reservation.close(() => resolve()))

    let releaseRecovery: (() => void) | undefined
    const recoveryGate = new Promise<void>((resolve) => {
      releaseRecovery = resolve
    })
    const gatedServices: CodevisorServerServices = {
      ...services,
      db: {
        ...services.db,
        listSessions: Effect.promise(async () => {
          await recoveryGate
          return await run(services.db.listSessions)
        })
      }
    }
    const starting = run(
      startCodevisorServer(gatedServices, defaultServerConfig({ id: "server-a", port }))
    )

    let recoveryResponse: Response | undefined
    await waitFor(
      async () => {
        try {
          const response = await fetch(`http://127.0.0.1:${port}/v1/health`)
          if (response.status !== 503) return false
          recoveryResponse = response
          return true
        } catch {
          return false
        }
      },
      () => "for the recovery-gated listener"
    )
    expect(await recoveryResponse?.json()).toEqual({
      error: "Server recovery is still in progress"
    })

    await new Promise<void>((resolve) => {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/events`)
      socket.once("error", () => resolve())
    })

    releaseRecovery?.()
    const server = await starting
    runningServers.push(server)
    expect(await (await fetch(`${server.url}/v1/health`)).json()).toMatchObject({ ok: true })
  })

  it("fails startup cleanly when orphan reconciliation cannot read sessions", async () => {
    const { services } = await makeServices("server-a")
    const failingServices: CodevisorServerServices = {
      ...services,
      db: {
        ...services.db,
        listSessions: Effect.sync(() => {
          throw new Error("recovery database unavailable")
        })
      }
    }

    await expect(
      run(startCodevisorServer(failingServices, defaultServerConfig({ id: "server-a", port: 0 })))
    ).rejects.toMatchObject({
      operation: "start",
      message: "recovery database unavailable"
    })
  })

  it("refuses to start when the port already has a listener", async () => {
    const { services } = await makeServices("server-a")
    const first = await run(
      startCodevisorServer(services, defaultServerConfig({ id: "server-a", port: 0 }))
    )
    runningServers.push(first)

    // A wildcard candidate must probe loopback, where an existing server is
    // already accepting clients, and reject before attempting its own bind.
    await expect(
      run(
        startCodevisorServer(
          services,
          defaultServerConfig({ host: "0.0.0.0", id: "server-b", port: first.port })
        )
      )
    ).rejects.toMatchObject({
      operation: "start",
      message: expect.stringContaining("already has a listener")
    })
  })

  it("serves tailnet peers from the mocked tailscale reader", async () => {
    const { server } = await start()

    vi.mocked(readTailnetPeers).mockResolvedValueOnce(undefined)
    expect((await jsonRequest(server, "/v1/tailnet/peers")).body).toEqual({
      available: false,
      peers: []
    })

    const peer = {
      hostName: "studio",
      dnsName: "studio.tail1234.ts.net",
      ip: "100.64.0.2",
      os: "macOS",
      online: true
    }
    vi.mocked(readTailnetPeers).mockResolvedValueOnce([peer])
    expect((await jsonRequest(server, "/v1/tailnet/peers")).body).toEqual({
      available: true,
      peers: [peer]
    })
  })

  it("serves health, info, OpenAPI, update state, pairing, and auth", async () => {
    const { server, services } = await start()

    expect((await jsonRequest(server, "/v1/health")).body).toMatchObject({
      database: "ready",
      ok: true,
      bootId: "test-boot",
      processId: process.pid,
      appOwned: false,
      serviceManaged: false
    })
    expect((await jsonRequest(server, "/v1/info")).body).toMatchObject({
      id: "server-a",
      kind: "local",
      machineId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      arch: process.arch,
      hostname: expect.any(String)
    })
    // cloudDeviceId is only advertised when the machine is cloud-connected.
    expect((await jsonRequest(server, "/v1/info")).body).not.toHaveProperty("cloudDeviceId")
    const discovery = await jsonRequest(server, "/v1/discovery")
    expect(discovery.body).toMatchObject({
      serverId: "server-a",
      machineId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      kind: "local",
      platform: process.platform,
      hostname: expect.any(String)
    })
    // The machine identity is stable across requests.
    expect((await jsonRequest(server, "/v1/discovery")).body).toMatchObject({
      machineId: (discovery.body as { machineId: string }).machineId
    })
    expect((await jsonRequest(server, "/v1/openapi.json")).body).toMatchObject({
      openapi: "3.1.0"
    })
    expect((await jsonRequest(server, "/v1/update")).body).toMatchObject({
      migrationState: "idle"
    })
    expect(defaultServerConfig()).toMatchObject({
      host: "127.0.0.1",
      id: "local",
      kind: "local",
      name: "Local Codevisor",
      port: 49361,
      version: "0.1.0",
      bootId: "test-boot",
      appOwned: false,
      serviceManaged: false
    })
    expect(
      (await jsonRequest(server, "/v1/auth/pairing-token", { method: "POST" })).body
    ).toMatchObject({
      token: expect.stringMatching(/^hm_/)
    })

    // The connection token is stable across calls, and rotation replaces it.
    const firstConnection = await jsonRequest(server, "/v1/auth/connection-token")
    expect(firstConnection.status).toBe(200)
    const connectionToken = (firstConnection.body as { token: string }).token
    expect(connectionToken).toMatch(/^hm_/)
    expect(
      ((await jsonRequest(server, "/v1/auth/connection-token")).body as { token: string }).token
    ).toBe(connectionToken)
    const rotation = await jsonRequest(server, "/v1/auth/connection-token/rotate", {
      method: "POST"
    })
    expect(rotation.status).toBe(201)
    expect((rotation.body as { token: string }).token).not.toBe(connectionToken)

    expect(defaultDatabasePath()).toContain("codevisor-server.sqlite")

    // Shutdown is acknowledged even when the host process installed no handler.
    expect((await jsonRequest(server, "/v1/shutdown", { method: "POST" })).status).toBe(202)

    let shutdownRequests = 0
    const stoppable = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({
          id: "server-stoppable",
          onShutdownRequested: () => {
            shutdownRequests += 1
          },
          port: 0
        })
      )
    )
    runningServers.push(stoppable)
    const shutdownResponse = await jsonRequest(stoppable, "/v1/shutdown", { method: "POST" })
    expect(shutdownResponse.status).toBe(202)
    expect(shutdownResponse.body).toMatchObject({ ok: true })
    expect(shutdownRequests).toBe(1)

    const token = await run(services.db.issuePairingToken)
    const secured = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({
          auth: {
            allowLocalhostWithoutAuth: false,
            requireBearerToken: true
          },
          id: "server-secure",
          port: 0
        })
      )
    )
    runningServers.push(secured)
    expect((await jsonRequest(secured, "/v1/info")).status).toBe(401)
    // Discovery stays reachable without a token so peers can be found.
    expect((await jsonRequest(secured, "/v1/discovery")).status).toBe(200)
    expect(
      (
        await jsonRequest(secured, "/v1/info", {
          headers: { Authorization: "Token nope" }
        })
      ).status
    ).toBe(401)
    expect(
      (
        await jsonRequest(secured, "/v1/info", {
          headers: { Authorization: "Bearer hm_wrong" }
        })
      ).status
    ).toBe(401)
    expect(
      (
        await jsonRequest(secured, "/v1/info", {
          headers: { Authorization: `Bearer ${token}` }
        })
      ).status
    ).toBe(200)
    const unauthorizedSocket = new WebSocket(
      `${secured.url.replace("http:", "ws:")}/v1/terminals/missing/socket`
    )
    await new Promise<void>((resolve) => {
      unauthorizedSocket.once("close", resolve)
      unauthorizedSocket.once("error", () => resolve())
    })

    const localhostSecured = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({
          auth: {
            allowLocalhostWithoutAuth: true,
            requireBearerToken: true
          },
          id: "server-local-secure",
          port: 0
        })
      )
    )
    runningServers.push(localhostSecured)
    expect((await jsonRequest(localhostSecured, "/v1/info")).status).toBe(200)
  })
})
