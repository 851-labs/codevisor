import { EventEmitter } from "node:events"
import { IncomingMessage, ServerResponse } from "node:http"
import { Socket } from "node:net"

import type { CloudSocket } from "@codevisor/cloud-client"
import { describe, expect, it } from "vitest"
import { WebSocket } from "ws"

import type { CloudServerControl, CodevisorServerConfig } from "../server-context.js"
import { defaultServerConfig, startCodevisorServer } from "../server.js"
import { jsonRequest, makeServices, run, runningServers } from "../test-support.js"
import { adaptDirectSocket, directHosts, routeNetDirect } from "./net-direct.js"
import { field, itemsOf } from "./response-test-support.js"

const interfaces = () => ({
  lo0: [{ address: "127.0.0.1", family: "IPv4", internal: true }],
  en0: [
    { address: "192.168.1.20", family: "IPv4", internal: false },
    { address: "fe80::1", family: "IPv6", internal: false }
  ],
  awdl0: [{ address: "169.254.7.7", family: "IPv4", internal: false }],
  utun9: undefined
})

const makeConfig = (overrides: Partial<CodevisorServerConfig>): CodevisorServerConfig =>
  defaultServerConfig({
    bootId: "test-boot",
    directPathEnabled: true,
    host: "0.0.0.0",
    port: 4931,
    ...overrides
  })

const cloudWithDevice = (deviceId: string): CloudServerControl => ({
  deviceId: () => deviceId,
  state: () => "connected",
  managedBy: () => "external",
  connect: () => Promise.resolve(deviceId),
  disconnect: () => Promise.resolve({ removedFromAccount: true })
})

class CapturedResponse extends ServerResponse {
  payload: unknown

  override end(chunk?: unknown): this {
    this.payload = JSON.parse(String(chunk))
    return this
  }
}

const captureJson = (): { response: ServerResponse; body: () => unknown } => {
  const response = new CapturedResponse(new IncomingMessage(new Socket()))
  return { response, body: () => response.payload }
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
      makeConfig({ cloud: cloudWithDevice("cloud-1") }),
      { method: "GET" },
      response,
      new URL("http://x/v1/net/direct")
    )
    expect(handled).toBe(true)
    expect(body()).toMatchObject({ deviceId: "cloud-1", port: 4931 })
    expect(itemsOf(field(body(), "hosts")).length).toBeGreaterThanOrEqual(0)
  })

  it("returns no hosts without a cloud identity, and ignores other routes", () => {
    const { response, body } = captureJson()
    routeNetDirect(makeConfig({}), { method: "GET" }, response, new URL("http://x/v1/net/direct"))
    expect(body()).toMatchObject({ deviceId: null, hosts: [] })

    expect(
      routeNetDirect(makeConfig({}), { method: "GET" }, response, new URL("http://x/v1/x"))
    ).toBe(false)
    expect(
      routeNetDirect(
        makeConfig({}),
        { method: "POST" },
        response,
        new URL("http://x/v1/net/direct")
      )
    ).toBe(false)
  })

  it("returns no hosts when direct paths are disabled", () => {
    const { response, body } = captureJson()
    routeNetDirect(
      makeConfig({
        cloud: cloudWithDevice("cloud-relay-only"),
        directPathEnabled: false
      }),
      { method: "GET" },
      response,
      new URL("http://x/v1/net/direct")
    )
    expect(body()).toEqual({ deviceId: "cloud-relay-only", hosts: [], port: 4931 })
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
      disconnect: () => Promise.resolve({ removedFromAccount: true }),
      acceptDirect: (socket: CloudSocket) => {
        accepted.push(socket)
        socket.send("welcome-from-host")
        return true
      }
    }
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ bootId: "test-boot", id: "server-direct", port: 0, cloud })
      )
    )
    runningServers.push(server)

    expect((await jsonRequest(server, "/v1/net/direct")).body).toMatchObject({
      deviceId: "device-direct"
    })

    const socket = new WebSocket(`${server.url.replace("http:", "ws:")}/v1/direct`)
    const greeting = await new Promise<string>((resolve, reject) => {
      socket.on("message", (data: Buffer) => resolve(data.toString()))
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
      disconnect: () => Promise.resolve({ removedFromAccount: true }),
      acceptDirect: () => false
    }
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ bootId: "test-boot", id: "server-direct-decline", port: 0, cloud })
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

  it("rejects /v1/direct when direct paths are disabled", async () => {
    const { services } = await makeServices("server-relay-only")
    let accepted = false
    const cloud = {
      deviceId: () => "device-relay-only",
      state: () => "connected" as const,
      managedBy: () => "external" as const,
      connect: () => Promise.resolve("device-relay-only"),
      disconnect: () => Promise.resolve({ removedFromAccount: true }),
      acceptDirect: () => {
        accepted = true
        return true
      }
    }
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({
          bootId: "test-boot",
          cloud,
          directPathEnabled: false,
          id: "server-relay-only",
          port: 0
        })
      )
    )
    runningServers.push(server)

    const outcome = await new Promise<"error" | "open">((resolve) => {
      const socket = new WebSocket(`${server.url.replace("http:", "ws:")}/v1/direct`)
      socket.on("open", () => resolve("open"))
      socket.on("error", () => resolve("error"))
    })
    expect(outcome).toBe("error")
    expect(accepted).toBe(false)
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
    })

    const adapted = adaptDirectSocket(socket)
    const seen: (string | Uint8Array)[] = []
    const closes: number[] = []
    // oxlint-disable-next-line unicorn/prefer-add-event-listener
    adapted.onmessage = (data) => seen.push(data)
    // oxlint-disable-next-line unicorn/prefer-add-event-listener
    adapted.onclose = (code) => closes.push(code)

    emitter.emit("message", Buffer.from("hello"), false)
    emitter.emit("message", Buffer.from([1, 2]), true)
    emitter.emit("message", [Buffer.from([3]), Buffer.from([4])], true)
    emitter.emit("close", 1005)
    emitter.emit("error", new Error("ignored"))

    expect(seen[0]).toBe("hello")
    expect(seen[1]).toEqual(new Uint8Array([1, 2]))
    expect(seen[2]).toEqual(new Uint8Array([3, 4]))
    expect(closes).toEqual([1005])

    adapted.send("out")
    adapted.close(1000, "bye")
    adapted.terminate?.()
    expect(sent).toEqual(["out", { close: 1000, reason: "bye" }, "terminated"])
  })

  it("ends the connection, not the server, when a message handler throws", () => {
    const emitter = new EventEmitter()
    const closes: unknown[] = []
    const socket = Object.assign(emitter, {
      send: () => undefined,
      close: (code?: number, reason?: string) => closes.push({ code, reason }),
      terminate: () => undefined
    })
    const adapted = adaptDirectSocket(socket)
    // oxlint-disable-next-line unicorn/prefer-add-event-listener
    adapted.onmessage = () => {
      throw new Error("handler bug")
    }

    emitter.emit("message", Buffer.from("hello"), false)

    expect(closes).toEqual([{ code: 1011, reason: "message handler failed" }])
  })
})
