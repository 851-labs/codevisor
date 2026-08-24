import type { CloudSocket } from "@codevisor/cloud-client"
import { EventEmitter } from "node:events"
import type { ServerResponse } from "node:http"
import { describe, expect, it } from "vitest"
import { WebSocket } from "ws"
import { adaptDirectSocket, directHosts, routeNetDirect } from "./net-direct.js"
import { defaultServerConfig, startCodevisorServer } from "../server.js"
import type { CodevisorServerConfig } from "../server-context.js"
import { jsonRequest, makeServices, run, runningServers } from "../test-support.js"

const interfaces = () => ({
  lo0: [{ address: "127.0.0.1", family: "IPv4", internal: true }],
  en0: [
    { address: "192.168.1.20", family: "IPv4", internal: false },
    { address: "fe80::1", family: "IPv6", internal: false }
  ],
  awdl0: [{ address: "169.254.7.7", family: "IPv4", internal: false }]
})

const makeConfig = (overrides: Partial<CodevisorServerConfig>): CodevisorServerConfig =>
  ({ host: "0.0.0.0", port: 4931, ...overrides }) as CodevisorServerConfig

const captureJson = (): { response: ServerResponse; body: () => unknown } => {
  let payload: unknown
  const response = {
    writeHead: () => response,
    end: (chunk: string) => {
      payload = JSON.parse(chunk)
    },
    setHeader: () => undefined
  } as unknown as ServerResponse
  return { response, body: () => payload }
}

describe("directHosts", () => {
  it("lists routable IPv4 addresses and skips loopback binds", () => {
    expect(directHosts("0.0.0.0", interfaces)).toEqual(["192.168.1.20"])
    expect(directHosts("127.0.0.1", interfaces)).toEqual([])
    expect(directHosts("localhost", interfaces)).toEqual([])
  })
})

describe("routeNetDirect", () => {
  it("reports the direct pipe's coordinates for a cloud-registered machine", () => {
    const { response, body } = captureJson()
    const handled = routeNetDirect(
      makeConfig({ cloud: { deviceId: () => "cloud-1" } as CodevisorServerConfig["cloud"] }),
      { method: "GET" } as never,
      response,
      new URL("http://x/v1/net/direct")
    )
    expect(handled).toBe(true)
    expect(body()).toMatchObject({ deviceId: "cloud-1", port: 4931 })
    expect((body() as { hosts: string[] }).hosts.length).toBeGreaterThanOrEqual(0)
  })

  it("returns no hosts without a cloud identity, and ignores other routes", () => {
    const { response, body } = captureJson()
    routeNetDirect(
      makeConfig({}),
      { method: "GET" } as never,
      response,
      new URL("http://x/v1/net/direct")
    )
    expect(body()).toMatchObject({ deviceId: null, hosts: [] })

    expect(
      routeNetDirect(makeConfig({}), { method: "GET" } as never, response, new URL("http://x/v1/x"))
    ).toBe(false)
    expect(
      routeNetDirect(
        makeConfig({}),
        { method: "POST" } as never,
        response,
        new URL("http://x/v1/net/direct")
      )
    ).toBe(false)
  })
})

describe("direct pipe on a running server", () => {
  it("upgrades /v1/direct into the bridge and serves discovery info", async () => {
    const { services } = await makeServices("server-direct")
    const accepted: CloudSocket[] = []
    const cloud = {
      deviceId: () => "device-direct",
      state: () => "connected" as const,
      managedBy: () => "external" as const,
      connect: () => Promise.resolve("device-direct"),
      disconnect: () => Promise.resolve(),
      acceptDirect: (socket: CloudSocket) => {
        accepted.push(socket)
        socket.send("welcome-from-host")
        return true
      }
    }
    const server = await run(
      startCodevisorServer(services, defaultServerConfig({ id: "server-direct", port: 0, cloud }))
    )
    runningServers.push(server)

    expect((await jsonRequest(server, "/v1/net/direct")).body).toMatchObject({
      deviceId: "device-direct"
    })

    const socket = new WebSocket(`${server.url.replace("http:", "ws:")}/v1/direct`)
    const greeting = await new Promise<string>((resolve, reject) => {
      socket.on("message", (data) => resolve(String(data)))
      socket.on("error", reject)
    })
    expect(greeting).toBe("welcome-from-host")
    expect(accepted).toHaveLength(1)
    socket.close()
  })

  it("closes /v1/direct with 1013 when the bridge declines the socket", async () => {
    const { services } = await makeServices("server-direct-decline")
    const cloud = {
      deviceId: () => undefined,
      state: () => undefined,
      managedBy: () => undefined,
      connect: () => Promise.resolve("unused"),
      disconnect: () => Promise.resolve(),
      acceptDirect: () => false
    }
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ id: "server-direct-decline", port: 0, cloud })
      )
    )
    runningServers.push(server)

    const socket = new WebSocket(`${server.url.replace("http:", "ws:")}/v1/direct`)
    const closeCode = await new Promise<number>((resolve, reject) => {
      socket.on("close", (code) => resolve(code))
      socket.on("error", reject)
    })
    expect(closeCode).toBe(1013)
  })
})

describe("adaptDirectSocket", () => {
  it("splits text/binary inbound and forwards socket controls", () => {
    const emitter = new EventEmitter()
    const sent: unknown[] = []
    const socket = Object.assign(emitter, {
      send: (data: unknown) => sent.push(data),
      close: (code?: number, reason?: string) => sent.push({ close: code, reason }),
      terminate: () => sent.push("terminated")
    }) as unknown as WebSocket

    const adapted = adaptDirectSocket(socket)
    const seen: (string | Uint8Array)[] = []
    const closes: number[] = []
    adapted.onmessage = (data) => seen.push(data)
    adapted.onclose = (code) => closes.push(code)

    emitter.emit("message", Buffer.from("hello"), false)
    emitter.emit("message", Buffer.from([1, 2]), true)
    emitter.emit("message", [Buffer.from([3]), Buffer.from([4])], true)
    emitter.emit("close", 1005)
    emitter.emit("error", new Error("ignored"))

    expect(seen[0]).toBe("hello")
    expect([...(seen[1] as Uint8Array)]).toEqual([1, 2])
    expect([...(seen[2] as Uint8Array)]).toEqual([3, 4])
    expect(closes).toEqual([1005])

    adapted.send("out")
    adapted.close(1000, "bye")
    adapted.terminate?.()
    expect(sent).toEqual(["out", { close: 1000, reason: "bye" }, "terminated"])
  })
})
