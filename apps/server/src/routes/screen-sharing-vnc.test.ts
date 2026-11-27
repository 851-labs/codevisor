import { chmodSync, realpathSync, rmSync, writeFileSync } from "node:fs"
import { createServer } from "node:net"
import { join } from "node:path"

import { describe, expect, it } from "vitest"
import { WebSocket } from "ws"

import { jsonRequest, makeServices, run, startWithApp } from "../test-support.js"
import {
  parseScreenSharingVNC,
  readDesktopSetup,
  SCREEN_SHARING_CONFIG_FILE,
  VNC_DISPLAY_ID
} from "./screen-sharing-vnc.js"
import {
  closed,
  closure,
  fakeVNC,
  nextMessage,
  privateDirectory,
  recordingSession,
  sharesAScreen,
  startWithDesktop as start,
  statusOf,
  streamsAgentViews,
  writeDesktopConfig
} from "./vnc-test-support.js"

describe("VNC screen sharing configuration", () => {
  it("reads the desktop's socket and names the desktop by default", () => {
    const dir = privateDirectory()
    expect(readDesktopSetup(dir)).toEqual({ kind: "absent" })
    writeDesktopConfig(dir, { socket: "/run/user/1000/codevisor-desktop.sock" })
    expect(readDesktopSetup(dir)).toEqual({
      kind: "ready",
      config: { socket: "/run/user/1000/codevisor-desktop.sock", name: "Desktop" }
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

  it("says the desktop isn't its own when the config names something that isn't its socket", async () => {
    const stray = join(privateDirectory(), "d.sock")
    writeFileSync(stray, "")
    const { capabilities } = await start({ socket: stray })
    expect((await capabilities()).body).toEqual({
      version: 1,
      status: "failed",
      provider: "vnc",
      message:
        "The desktop on this machine isn't run by the account Codevisor runs as, so Codevisor won't share it.",
      displays: []
    })
  })

  it("logs which folder lets other accounts in, once, however often viewers ask", async () => {
    const home = privateDirectory()
    const vnc = await fakeVNC(home)
    const lines: string[] = []
    const { capabilities } = await start({ socket: vnc.socket }, undefined, undefined, (line) =>
      lines.push(line)
    )
    chmodSync(home, 0o775)
    await capabilities()
    await capabilities()
    expect(lines).toEqual([
      `[desktop] not shared: ${realpathSync(home)} can be changed by other accounts (mode 775, belongs to uid ${process.getuid!()})`
    ])

    chmodSync(home, 0o700)
    expect((await capabilities()).body).toMatchObject({ status: "available" })
    chmodSync(home, 0o775)
    await capabilities()
    expect(lines).toHaveLength(2)
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

  it("lists a desktop's features from one look at it, so they can't disagree mid-rewrite", async () => {
    const config = { socket: "/run/user/1000/codevisor-desktop.sock", name: "Desktop" }
    const looks = [{ displays: [config], respond: async () => undefined }, undefined]
    const { services } = await makeServices()
    const server = await startWithApp(services, undefined, {
      desktops: { current: () => looks.shift() }
    })
    expect((await jsonRequest(server, "/v1/info")).body).toMatchObject({
      features: expect.arrayContaining(["screen-sharing-v1", "computer-use-stream-v1"])
    })
    expect(looks).toHaveLength(1)
  })

  it("stops offering a desktop whose config no longer names anything to share", async () => {
    const vnc = await fakeVNC()
    const { info, dataDir } = await start({ socket: vnc.socket })
    expect(await info()).toMatchObject(sharesAScreen)
    writeFileSync(join(dataDir, SCREEN_SHARING_CONFIG_FILE), '{ "vnc": { "name": "Desktop" } }')
    expect(await info()).not.toMatchObject(sharesAScreen)
  })
})

describe("a desktop set up for an older Codevisor, whose config names a local port", () => {
  it("stays listed and says it needs setting up again, is logged once, and is never dialled", async ({
    onTestFinished
  }) => {
    let dialled = 0
    const oldDesktop = createServer(() => {
      dialled += 1
    })
    await new Promise<void>((resolve) => oldDesktop.listen(0, "127.0.0.1", resolve))
    onTestFinished(() => new Promise<void>((resolve) => oldDesktop.close(() => resolve())))
    const address = oldDesktop.address()
    const port = typeof address === "object" && address !== null ? address.port : 0
    const lines: string[] = []
    const { socketUrl, ask, capabilities, info, dataDir } = await start(
      { port, name: "Desktop", desktop: "xfce", defaultSize: "1440x900" },
      undefined,
      undefined,
      (line) => lines.push(line)
    )
    const needsSetup = {
      status: 200,
      body: {
        version: 1,
        status: "failed",
        provider: "vnc",
        message:
          "This machine's desktop was set up for an older version of Codevisor. Set it up again to share it.",
        displays: []
      }
    }
    expect(await info()).toMatchObject(sharesAScreen)
    expect(await capabilities()).toEqual(needsSetup)
    expect(await ask({ operation: "setScale", displayId: VNC_DISPLAY_ID, scale: 2 })).toEqual(
      needsSetup
    )
    await expect(nextMessage(new WebSocket(socketUrl()))).rejects.toThrow()
    expect(dialled).toBe(0)
    expect(lines).toEqual([expect.stringContaining("names a VNC port")])
    expect(await info()).not.toMatchObject(streamsAgentViews)

    const vnc = await fakeVNC()
    writeDesktopConfig(dataDir, { socket: vnc.socket })
    expect(await info()).toMatchObject(streamsAgentViews)
    expect(lines).toHaveLength(1)
    writeDesktopConfig(dataDir, { port })
    expect(await capabilities()).toEqual(needsSetup)
    expect(lines).toHaveLength(2)
  })

  it.each([
    { socket: "run/codevisor-desktop.sock", port: 5901 },
    { socket: "", port: 5901 },
    { socket: null, port: 5901 },
    { port: 0 },
    { port: "5901" },
    { name: "Desktop" }
  ])(
    "is not what %j is taken for: that is not offered, and logged once as unusable",
    async (vnc) => {
      const lines: string[] = []
      const { info } = await start(vnc, undefined, undefined, (line) => lines.push(line))
      expect(await info()).not.toMatchObject(sharesAScreen)
      expect(await info()).not.toMatchObject(sharesAScreen)
      expect(lines).toEqual([expect.stringContaining("has no usable socket")])
    }
  )

  it("logs nothing for a file with no vnc section", async () => {
    const lines: string[] = []
    const { info, dataDir } = await start(undefined, undefined, undefined, (line) =>
      lines.push(line)
    )
    writeFileSync(join(dataDir, SCREEN_SHARING_CONFIG_FILE), '{ "devContainerDesktop": true }')
    expect(await info()).not.toMatchObject(sharesAScreen)
    expect(lines).toEqual([])
  })
})
