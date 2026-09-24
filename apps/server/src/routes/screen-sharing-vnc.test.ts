import { randomUUID } from "node:crypto"
import { mkdtempSync, writeFileSync } from "node:fs"
import { createServer, type Server, type Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"
import { WebSocket } from "ws"

import type { ScreenSharingVNCConfig } from "../server-context-types.js"
import { jsonRequest, makeServices, run, runningServers, startWithApp } from "../test-support.js"
import {
  parseScreenSharingVNC,
  readScreenSharingVNC,
  vncDisplayId,
  vncScreenSharing
} from "./screen-sharing-vnc.js"

describe("VNC screen sharing configuration", () => {
  it("reads the operator's file and names the desktop by default", () => {
    const dir = mkdtempSync(join(tmpdir(), "codevisor-vnc-"))
    expect(readScreenSharingVNC(dir)).toBeUndefined()
    writeFileSync(join(dir, "screen-sharing.json"), '{ "vnc": { "port": 5901 } }')
    expect(readScreenSharingVNC(dir)).toEqual({ port: 5901, name: "Desktop" })
  })

  it("reads the desktop kind and its provisioned size (851-2339)", () => {
    expect(
      parseScreenSharingVNC(
        '{ "vnc": { "port": 5901, "desktop": "xfce", "defaultSize": "1440x900" } }'
      )
    ).toEqual({
      port: 5901,
      name: "Desktop",
      desktop: "xfce",
      defaultWidth: 1440,
      defaultHeight: 900
    })
    expect(
      parseScreenSharingVNC('{ "vnc": { "port": 5901, "desktop": "gnome", "defaultSize": "big" } }')
    ).toEqual({ port: 5901, name: "Desktop" })
  })

  it("ignores anything but a loopback port", () => {
    for (const text of [
      "",
      "{",
      "null",
      "42",
      "[]",
      '{ "vnc": null }',
      '{ "vnc": { "port": 0 } }',
      '{ "vnc": { "port": "5901" } }',
      '{ "vnc": { "port": 70000 } }'
    ])
      expect(parseScreenSharingVNC(text)).toBeUndefined()
    expect(parseScreenSharingVNC('{ "vnc": { "port": 5902, "name": " Studio " } }')).toEqual({
      port: 5902,
      name: "Studio"
    })
  })
})

/// Greets like an RFB server, then echoes whatever it receives.
const fakeVNC = async (): Promise<{ server: Server; port: number; connections: Socket[] }> => {
  const connections: Socket[] = []
  const server = createServer((socket) => {
    connections.push(socket)
    socket.write("RFB 003.008\n")
    socket.on("data", (chunk) => socket.write(chunk))
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const address = server.address()
  const port = typeof address === "object" && address !== null ? address.port : 0
  return { server, port, connections }
}

const nextMessage = (socket: WebSocket): Promise<Buffer> =>
  new Promise((resolve, reject) => {
    socket.once("message", (data) => resolve(Buffer.from(data as Buffer)))
    socket.once("error", reject)
    socket.once("close", (code) => reject(new Error(`closed ${code}`)))
  })

const closed = (socket: WebSocket): Promise<number> =>
  new Promise((resolve) => socket.once("close", resolve))

const start = async (
  config: ScreenSharingVNCConfig,
  auth?: { allowLocalhostWithoutAuth: boolean; requireBearerToken: boolean }
) => {
  const { services } = await makeServices()
  const server = await startWithApp(services, undefined, {
    screenSharing: vncScreenSharing(config),
    screenSharingVNC: config,
    ...(auth === undefined ? {} : { auth })
  })
  runningServers.push(server)
  const socketUrl = (displayId: string) =>
    `ws://127.0.0.1:${server.port}/v1/screen-sharing/vnc/socket?displayId=${displayId}`
  return { services, server, socketUrl }
}

describe("VNC screen sharing provider", () => {
  const cleanups: Array<() => void> = []
  afterEach(() => {
    for (const cleanup of cleanups.splice(0)) cleanup()
  })

  it("advertises screen sharing with the desktop as the only display", async () => {
    const config = { port: 5901, name: "Studio" }
    const { server } = await start(config)
    const info = await jsonRequest(server, "/v1/info")
    expect((info.body as { features: string[] }).features).toContain("screen-sharing-v1")
    const reply = await jsonRequest(server, "/v1/screen-sharing", {
      method: "POST",
      body: JSON.stringify({
        version: 1,
        operation: "capabilities",
        workspaceId: randomUUID(),
        paneId: randomUUID(),
        viewerId: randomUUID()
      })
    })
    expect(reply).toEqual({
      status: 200,
      body: {
        version: 1,
        status: "available",
        provider: "vnc",
        displays: [{ id: "vnc:5901", name: "Studio", width: 0, height: 0 }]
      }
    })
  })

  it("splices a WebSocket onto the loopback VNC server both ways", async () => {
    const vnc = await fakeVNC()
    cleanups.push(() => vnc.server.close())
    const config = { port: vnc.port, name: "Desktop" }
    const { socketUrl } = await start(config)
    const socket = new WebSocket(socketUrl(vncDisplayId(config)))
    expect((await nextMessage(socket)).toString()).toBe("RFB 003.008\n")
    const echoed = nextMessage(socket)
    socket.send(Buffer.from([0x52, 0x46, 0x42, 0x00]))
    expect([...(await echoed)]).toEqual([0x52, 0x46, 0x42, 0x00])
    socket.close()
    await closed(socket)
    await new Promise<void>((resolve) => vnc.connections[0]!.once("close", () => resolve()))
    expect(vnc.connections).toHaveLength(1)
  })

  it("reports that stop signaling is unsupported by the VNC provider", async () => {
    const { server } = await start({ port: 5901, name: "Desktop" })
    const reply = await jsonRequest(server, "/v1/screen-sharing", {
      method: "POST",
      body: JSON.stringify({
        version: 1,
        operation: "stop",
        workspaceId: randomUUID(),
        paneId: randomUUID(),
        viewerId: randomUUID()
      })
    })
    expect(reply).toEqual({
      status: 200,
      body: {
        version: 1,
        status: "unsupported",
        provider: "vnc",
        message: "This machine streams its display over the VNC socket",
        displays: []
      }
    })
  })

  it("closes the upstream connection when a WebSocket frame is invalid", async ({
    onTestFinished
  }) => {
    const vnc = await fakeVNC()
    onTestFinished(async () => {
      for (const connection of vnc.connections) connection.destroy()
      await new Promise<void>((resolve) => vnc.server.close(() => resolve()))
    })
    const config = { port: vnc.port, name: "Desktop" }
    const { socketUrl } = await start(config)
    const socket = new WebSocket(socketUrl(vncDisplayId(config)))
    onTestFinished(async () => {
      if (socket.readyState === WebSocket.CLOSED) return
      const closing = closed(socket)
      socket.terminate()
      await closing
    })
    await nextMessage(socket)
    const upstream = vnc.connections[0]!
    const upstreamClosed = new Promise<void>((resolve) => upstream.once("close", () => resolve()))
    const socketClosed = closed(socket)
    socket.send(Buffer.from([0xff]), { binary: false })
    expect(await socketClosed).toBe(1007)
    await upstreamClosed
    expect(upstream.destroyed).toBe(true)
  })

  it("ends the socket when the VNC server hangs up", async () => {
    const vnc = await fakeVNC()
    cleanups.push(() => vnc.server.close())
    const config = { port: vnc.port, name: "Desktop" }
    const { socketUrl } = await start(config)
    const socket = new WebSocket(socketUrl(vncDisplayId(config)))
    await nextMessage(socket)
    vnc.connections[0]!.destroy()
    expect(await closed(socket)).toBe(1005)
  })

  it("refuses a stale display id, browsers, and a missing VNC server", async () => {
    const vnc = await fakeVNC()
    const config = { port: vnc.port, name: "Desktop" }
    const { socketUrl } = await start(config)
    const statusOf = (socket: WebSocket) =>
      new Promise<number>((resolve) => {
        socket.once("unexpected-response", (_request, response) =>
          resolve(response.statusCode ?? 0)
        )
        socket.once("error", () => undefined)
      })
    expect(await statusOf(new WebSocket(socketUrl("vnc:1")))).toBe(404)
    expect(
      await statusOf(
        new WebSocket(socketUrl(vncDisplayId(config)), {
          headers: { origin: "https://evil.example" }
        })
      )
    ).toBe(403)
    await new Promise<void>((resolve) => vnc.server.close(() => resolve()))
    const orphan = new WebSocket(socketUrl(vncDisplayId(config)))
    expect(await closed(orphan)).toBe(1011)
  })

  it("requires the machine token when loopback is not trusted", async () => {
    const config = { port: 5901, name: "Desktop" }
    const { services, socketUrl } = await start(config, {
      allowLocalhostWithoutAuth: false,
      requireBearerToken: true
    })
    const status = await new Promise<number>((resolve) => {
      const socket = new WebSocket(socketUrl(vncDisplayId(config)))
      socket.once("unexpected-response", (_request, response) => resolve(response.statusCode ?? 0))
      socket.once("error", () => undefined)
    })
    expect(status).toBe(401)
    const token = await run(services.db.issuePairingToken)
    expect(typeof token).toBe("string")
  })
})
