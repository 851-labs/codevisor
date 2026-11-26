import { chmodSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"
import { WebSocket, type RawData } from "ws"

import { jsonRequest, makeServices, run, startWithApp } from "../test-support.js"
import type { ScalerCommands } from "./screen-sharing-vnc-scale.js"
import {
  parseScreenSharingVNC,
  readScreenSharingVNC,
  SCREEN_SHARING_CONFIG_FILE,
  VNC_DISPLAY_ID
} from "./screen-sharing-vnc.js"
import { fileVNCDesktops } from "./vnc-desktops.js"
import {
  fakeVNC,
  privateDirectory,
  recordingSession,
  writeDesktopConfig
} from "./vnc-test-support.js"

describe("VNC screen sharing configuration", () => {
  it("reads the desktop's socket and names the desktop by default", () => {
    const dir = privateDirectory()
    expect(readScreenSharingVNC(dir)).toBeUndefined()
    writeDesktopConfig(dir, { socket: "/run/user/1000/codevisor-desktop.sock" })
    expect(readScreenSharingVNC(dir)).toEqual({
      socket: "/run/user/1000/codevisor-desktop.sock",
      name: "Desktop"
    })
  })

  it("reads the desktop kind, its X11 display and cookie, and its provisioned size (851-2339)", () => {
    const socket = "/run/user/1000/codevisor-desktop.sock"
    expect(
      parseScreenSharingVNC(
        JSON.stringify({
          vnc: {
            socket,
            name: " Studio ",
            desktop: "xfce",
            display: 1,
            xauthority: "/run/user/1000/codevisor-desktop.xauth",
            defaultSize: "1440x900"
          }
        })
      )
    ).toEqual({
      socket,
      name: "Studio",
      desktop: "xfce",
      display: 1,
      xauthority: "/run/user/1000/codevisor-desktop.xauth",
      defaultWidth: 1440,
      defaultHeight: 900
    })
    expect(
      parseScreenSharingVNC(
        JSON.stringify({
          vnc: { socket, desktop: "gnome", display: -1, xauthority: "cookie", defaultSize: "big" }
        })
      )
    ).toEqual({ socket, name: "Desktop" })
  })

  it("ignores anything but a socket path, including a port a local account could dial", () => {
    for (const text of [
      "",
      "{",
      "null",
      "42",
      "[]",
      '{ "vnc": null }',
      '{ "vnc": {} }',
      '{ "vnc": { "port": 5901 } }',
      '{ "vnc": { "port": 5901, "socket": 5901 } }',
      '{ "vnc": { "socket": "codevisor-desktop.sock" } }'
    ])
      expect(parseScreenSharingVNC(text)).toBeUndefined()
  })
})

const bytesOf = (data: RawData): Buffer =>
  Array.isArray(data) ? Buffer.concat(data) : Buffer.from(new Uint8Array(data))

const nextMessage = (socket: WebSocket): Promise<Buffer> =>
  new Promise((resolve, reject) => {
    socket.once("message", (data) => resolve(bytesOf(data)))
    socket.once("error", reject)
    socket.once("close", (code) => reject(new Error(`closed ${code}`)))
  })

const closed = (socket: WebSocket): Promise<number> =>
  new Promise((resolve) => socket.once("close", resolve))

const closure = (socket: WebSocket): Promise<{ code: number; reason: string }> =>
  new Promise((resolve) =>
    socket.once("close", (code, reason) => resolve({ code, reason: reason.toString() }))
  )

const statusOf = (socket: WebSocket) =>
  new Promise<number>((resolve) => {
    socket.once("unexpected-response", (_request, response) => resolve(response.statusCode ?? 0))
    socket.once("error", () => undefined)
  })

const identity = {
  workspaceId: "0b0f4a52-6a4f-4f0a-9a43-0d0b2f6d7c11",
  paneId: "0b0f4a52-6a4f-4f0a-9a43-0d0b2f6d7c12",
  viewerId: "0b0f4a52-6a4f-4f0a-9a43-0d0b2f6d7c13",
  app: { key: "a".repeat(64), name: "Studio Mac" }
}

const sharesAScreen = { features: expect.arrayContaining(["screen-sharing-v1"]) }

const start = async (
  vnc?: Record<string, unknown>,
  auth?: { allowLocalhostWithoutAuth: boolean; requireBearerToken: boolean },
  commands?: ScalerCommands
) => {
  const dataDir = privateDirectory()
  if (vnc !== undefined) writeDesktopConfig(dataDir, vnc)
  const { services } = await makeServices()
  const server = await startWithApp(services, undefined, {
    desktops: fileVNCDesktops(dataDir, commands),
    ...(auth === undefined ? {} : { auth })
  })
  const socketUrl = (displayId: string = VNC_DISPLAY_ID) =>
    `ws://127.0.0.1:${server.port}/v1/screen-sharing/vnc/socket?displayId=${displayId}`
  const ask = (request: Record<string, unknown>) =>
    jsonRequest(server, "/v1/screen-sharing", {
      method: "POST",
      body: JSON.stringify({ version: 1, ...identity, ...request })
    })
  const capabilities = () => ask({ operation: "capabilities" })
  const info = async (): Promise<unknown> => (await jsonRequest(server, "/v1/info")).body
  return { services, server, socketUrl, ask, capabilities, info, dataDir }
}

describe("VNC screen sharing provider", () => {
  it("splices a WebSocket onto the desktop's private socket both ways", async () => {
    const vnc = await fakeVNC()
    const { socketUrl } = await start({ socket: vnc.socket })
    const socket = new WebSocket(socketUrl())
    expect((await nextMessage(socket)).toString()).toBe("RFB 003.008\n")
    const echoed = nextMessage(socket)
    socket.send(Buffer.from([0x52, 0x46, 0x42, 0x00]))
    expect([...(await echoed)]).toEqual([0x52, 0x46, 0x42, 0x00])
    socket.close()
    await closed(socket)
    await new Promise<void>((resolve) => vnc.connections[0]!.once("close", () => resolve()))
    expect(vnc.connections).toHaveLength(1)
  })

  it("gives control to one viewer at a time, last one wins (851-2338)", async ({
    onTestFinished
  }) => {
    const vnc = await fakeVNC()
    const { socketUrl } = await start({ socket: vnc.socket })
    const handshake = Buffer.concat([Buffer.from("RFB 003.008\n", "latin1"), Buffer.from([1, 1])])
    const key = Buffer.from([4, 1, 0, 0, 0, 0, 0, 0x61])
    const request = Buffer.from([3, 1, 0, 0, 0, 0, 0, 64, 0, 48])
    const open = async () => {
      const socket = new WebSocket(socketUrl())
      onTestFinished(async () => {
        if (socket.readyState === WebSocket.CLOSED) return
        const closing = closed(socket)
        socket.terminate()
        await closing
      })
      await nextMessage(socket)
      const echoed = nextMessage(socket)
      socket.send(handshake)
      expect(await echoed).toEqual(handshake)
      return socket
    }
    const a = await open()
    const b = await open()
    const granted = nextMessage(a)
    a.send(JSON.stringify({ type: "request", name: "Studio" }))
    expect(JSON.parse((await granted).toString())).toEqual({ type: "granted" })
    const revoked = nextMessage(a)
    const grantedB = nextMessage(b)
    b.send(JSON.stringify({ type: "request", name: "Laptop" }))
    expect(JSON.parse((await revoked).toString())).toEqual({ type: "revoked", by: "Laptop" })
    expect(JSON.parse((await grantedB).toString())).toEqual({ type: "granted" })
    const echoedA = nextMessage(a)
    a.send(key)
    a.send(request)
    expect(await echoedA).toEqual(request)
    const echoedB = nextMessage(b)
    b.send(key)
    expect(await echoedB).toEqual(key)
    const resize = Buffer.concat([Buffer.from([251, 0, 4, 0, 3, 0, 1, 0]), Buffer.alloc(16, 5)])
    const resizedB = nextMessage(b)
    b.send(resize)
    expect(await resizedB).toEqual(resize)
    const afterResizeA = nextMessage(a)
    a.send(resize)
    a.send(request)
    expect(await afterResizeA).toEqual(request)
    for (const socket of [a, b]) {
      const done = closed(socket)
      socket.close()
      await done
    }
  })

  it("closes the upstream connection when a WebSocket frame is invalid", async ({
    onTestFinished
  }) => {
    const vnc = await fakeVNC()
    const { socketUrl } = await start({ socket: vnc.socket })
    const socket = new WebSocket(socketUrl())
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
    const { socketUrl } = await start({ socket: vnc.socket })
    const socket = new WebSocket(socketUrl())
    await nextMessage(socket)
    vnc.connections[0]!.destroy()
    expect(await closed(socket)).toBe(1005)
  })

  it("refuses a stale display id, browsers, and a missing VNC server", async () => {
    const vnc = await fakeVNC()
    const { socketUrl } = await start({ socket: vnc.socket })
    expect(await statusOf(new WebSocket(socketUrl("vnc:1")))).toBe(404)
    expect(
      await statusOf(
        new WebSocket(socketUrl(), {
          headers: { origin: "https://evil.example" }
        })
      )
    ).toBe(403)
    await new Promise<void>((resolve) => vnc.server.close(() => resolve()))
    const orphan = new WebSocket(socketUrl())
    expect(await closure(orphan)).toEqual({
      code: 1011,
      reason: "The desktop on this machine isn't running."
    })
  })

  it("requires the machine token when loopback is not trusted", async () => {
    const vnc = await fakeVNC()
    const { services, socketUrl } = await start(
      { socket: vnc.socket },
      { allowLocalhostWithoutAuth: false, requireBearerToken: true }
    )
    const status = await new Promise<number>((resolve) => {
      const socket = new WebSocket(socketUrl())
      socket.once("unexpected-response", (_request, response) => resolve(response.statusCode ?? 0))
      socket.once("error", () => undefined)
    })
    expect(status).toBe(401)
    const token = await run(services.db.issuePairingToken)
    const authorized = new WebSocket(socketUrl(), {
      headers: { authorization: `Bearer ${token}` }
    })
    expect((await nextMessage(authorized)).toString()).toBe("RFB 003.008\n")
    const done = closed(authorized)
    authorized.close()
    await done
  })

  it("won't relay a socket another account could open, and says why", async () => {
    const vnc = await fakeVNC()
    const { socketUrl, capabilities } = await start({ socket: vnc.socket })
    chmodSync(vnc.socket, 0o666)
    const message =
      "Other accounts on this machine can reach its desktop, so Codevisor won't share it."
    expect(await closure(new WebSocket(socketUrl()))).toEqual({ code: 1011, reason: message })
    expect(vnc.connections).toHaveLength(0)
    expect((await capabilities()).body).toEqual({
      version: 1,
      status: "failed",
      provider: "vnc",
      message,
      displays: []
    })
  })

  it("sets the desktop's scale when a viewer names the desktop's display", async () => {
    const session = recordingSession()
    const { ask } = await start(
      { socket: "/run/user/1000/codevisor-desktop.sock", desktop: "xfce", display: 1 },
      undefined,
      session.commands
    )
    const scaled = await ask({ operation: "setScale", displayId: VNC_DISPLAY_ID, scale: 2 })
    expect(scaled).toEqual({
      status: 200,
      body: { version: 1, status: "ok", provider: "vnc", displays: [] }
    })
    expect(session.environments.length).toBeGreaterThan(0)
    expect((await ask({ operation: "setScale", displayId: "vnc:other", scale: 2 })).status).toBe(
      400
    )
  })

  it("says the desktop isn't running when its socket is gone", async () => {
    const { capabilities } = await start({ socket: join(privateDirectory(), "d.sock") })
    expect((await capabilities()).body).toEqual({
      version: 1,
      status: "failed",
      provider: "vnc",
      message: "The desktop on this machine isn't running.",
      displays: []
    })
  })
})

describe("a desktop that appears or goes away while the server keeps running", () => {
  it("is offered once its config is written and withdrawn once it is removed", async () => {
    const { socketUrl, capabilities, info, dataDir } = await start()
    expect(await info()).not.toMatchObject(sharesAScreen)
    expect(await capabilities()).toEqual({
      status: 501,
      body: { error: "This machine has no desktop to share" }
    })
    await expect(nextMessage(new WebSocket(socketUrl()))).rejects.toThrow()

    const vnc = await fakeVNC()
    writeDesktopConfig(dataDir, { socket: vnc.socket, name: "Lab" })
    expect(await info()).toMatchObject(sharesAScreen)
    expect((await capabilities()).body).toMatchObject({
      status: "available",
      displays: [{ id: VNC_DISPLAY_ID, name: "Lab" }]
    })
    const socket = new WebSocket(socketUrl())
    expect((await nextMessage(socket)).toString()).toBe("RFB 003.008\n")
    const done = closed(socket)
    socket.close()
    await done

    rmSync(join(dataDir, SCREEN_SHARING_CONFIG_FILE))
    expect(await info()).not.toMatchObject(sharesAScreen)
    expect((await capabilities()).status).toBe(501)
  })

  it("stops offering a desktop whose config no longer names a socket", async () => {
    const vnc = await fakeVNC()
    const { info, dataDir } = await start({ socket: vnc.socket })
    expect(await info()).toMatchObject(sharesAScreen)
    writeFileSync(join(dataDir, SCREEN_SHARING_CONFIG_FILE), '{ "vnc": { "port": 5901 } }')
    expect(await info()).not.toMatchObject(sharesAScreen)
  })
})
