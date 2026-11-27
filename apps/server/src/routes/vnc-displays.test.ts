import { rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"
import { WebSocket } from "ws"

import type { ScreenSharingVNCConfig } from "../server-context-types.js"
import { jsonRequest, makeServices, startWithApp } from "../test-support.js"
import { SCREEN_SHARING_CONFIG_FILE } from "./screen-sharing-vnc.js"
import { fileVNCDesktops } from "./vnc-desktops.js"
import {
  closed,
  closure,
  fakeVNC,
  nextMessage,
  privateDirectory,
  sharesAScreen,
  statusOf
} from "./vnc-test-support.js"

const identity = {
  version: 1,
  workspaceId: "0b0f4a52-6a4f-4f0a-9a43-0d0b2f6d7c11",
  paneId: "0b0f4a52-6a4f-4f0a-9a43-0d0b2f6d7c12",
  viewerId: "0b0f4a52-6a4f-4f0a-9a43-0d0b2f6d7c13",
  app: { key: "a".repeat(64), name: "Studio Mac" }
}

const nobodyThere = "Nobody is logged in at this machine's screen, so there is nothing to show."
const greeting = Buffer.from("RFB 003.008\n", "latin1")
const handshake = Buffer.concat([greeting, Buffer.from([1, 1])])
const key = Buffer.from([4, 1, 0, 0, 0, 0, 0, 97])
const resize = Buffer.concat([Buffer.from([251, 0, 4, 0, 3, 0, 1, 0]), Buffer.alloc(16, 5)])

const machineWith = async (sockets: { desktop?: string; screen?: string }) => {
  const dataDir = privateDirectory()
  const displays = [
    ...(sockets.desktop === undefined
      ? []
      : [{ id: "desktop", vnc: { socket: sockets.desktop, name: "Desktop" }, service: "process" }]),
    ...(sockets.screen === undefined
      ? []
      : [{ id: "screen", vnc: { socket: sockets.screen, name: "Screen" }, service: "server" }])
  ]
  writeFileSync(join(dataDir, SCREEN_SHARING_CONFIG_FILE), JSON.stringify({ displays }))
  const joined: ScreenSharingVNCConfig[] = []
  const desktops = fileVNCDesktops(dataDir, {
    viewerJoined: (display) => void joined.push(display)
  })
  const { services } = await makeServices()
  const server = await startWithApp(services, undefined, { desktops })
  const capabilities = async () =>
    (
      await jsonRequest(server, "/v1/screen-sharing", {
        method: "POST",
        body: JSON.stringify({ ...identity, operation: "capabilities" })
      })
    ).body
  const open = (displayId: string) =>
    new WebSocket(
      `ws://127.0.0.1:${server.port}/v1/screen-sharing/vnc/socket?displayId=${displayId}`
    )
  const info = async (): Promise<unknown> => (await jsonRequest(server, "/v1/info")).body
  return { capabilities, open, info, joined, desktops }
}

const hungUp = async (socket: WebSocket): Promise<void> => {
  if (socket.readyState === WebSocket.CLOSED) return

  const closing = closed(socket)
  socket.terminate()
  await closing
}

const connected = async (socket: WebSocket) => {
  onTestFinished(() => hungUp(socket))
  expect(await nextMessage(socket)).toEqual(greeting)
  const echoed = nextMessage(socket)
  socket.send(handshake)
  expect(await echoed).toEqual(handshake)
  return socket
}

describe("a Linux machine with a desktop and a real screen", () => {
  it("lists the desktop first and the screen second, like a Mac with two monitors", async () => {
    const [desktop, screen] = [await fakeVNC(), await fakeVNC()]
    const machine = await machineWith({ desktop: desktop.socket, screen: screen.socket })

    expect(await machine.capabilities()).toMatchObject({
      status: "available",
      provider: "vnc",
      displays: [
        { id: "vnc:desktop", name: "Desktop" },
        { id: "vnc:screen", name: "Screen" }
      ]
    })
  })

  it("lists only the desktop while nobody is logged in at the screen", async () => {
    const desktop = await fakeVNC()
    const machine = await machineWith({
      desktop: desktop.socket,
      screen: join(privateDirectory(), "codevisor-screen.sock")
    })

    expect(await machine.capabilities()).toMatchObject({
      status: "available",
      displays: [{ id: "vnc:desktop" }]
    })
  })

  it("says nobody is logged in when the screen is all it shares", async () => {
    const machine = await machineWith({ screen: join(privateDirectory(), "codevisor-screen.sock") })

    expect(await machine.capabilities()).toMatchObject({ status: "failed", message: nobodyThere })
    expect(await machine.info()).toMatchObject(sharesAScreen)
  })

  it("relays each display to its own server, and reports a viewer of either", async () => {
    const [desktop, screen] = [await fakeVNC(), await fakeVNC()]
    const machine = await machineWith({ desktop: desktop.socket, screen: screen.socket })

    const onTheScreen = await connected(machine.open("vnc:screen"))
    expect([desktop.connections.length, screen.connections.length]).toEqual([0, 1])

    const onTheDesktop = await connected(machine.open("vnc:desktop"))
    expect([desktop.connections.length, screen.connections.length]).toEqual([1, 1])
    expect(machine.joined.map((display) => display.name)).toEqual(["Screen", "Desktop"])

    const unknown = machine.open("vnc:monitor")
    expect(await statusOf(unknown)).toBe(404)
    unknown.terminate()
    await Promise.all([onTheScreen, onTheDesktop].map(hungUp))
  })

  it("passes a viewer's keys to the screen but not a request to resize it", async () => {
    const screen = await fakeVNC()
    const machine = await machineWith({ screen: screen.socket })
    const viewer = await connected(machine.open("vnc:screen"))

    const echoed = nextMessage(viewer)
    viewer.send(resize)
    viewer.send(key)

    expect(await echoed).toEqual(key)
    await hungUp(viewer)
  })

  it("disconnects a viewer of the screen, with the reason, when the session ends", async () => {
    const screen = await fakeVNC()
    const machine = await machineWith({ screen: screen.socket })
    const viewer = await connected(machine.open("vnc:screen"))
    const ended = closure(viewer)

    rmSync(screen.socket)
    machine.desktops.relays?.recheck()

    expect(await ended).toEqual({ code: 1011, reason: nobodyThere })
  })
})
