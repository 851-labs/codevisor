import { EventEmitter } from "node:events"
import { chmodSync, rmSync } from "node:fs"
import { IncomingMessage } from "node:http"
import { Socket } from "node:net"
import { join } from "node:path"

import { describe, expect, it, vi } from "vitest"
import { WebSocket } from "ws"

import {
  SCREEN_SHARING_CONFIG_FILE,
  spliceVNCSocket,
  VNC_DISPLAY_ID,
  VNC_SCREEN_ID
} from "./screen-sharing-vnc.js"
import { VNCControlArbiter } from "./vnc-control.js"
import { VNCRelays } from "./vnc-relays.js"
import {
  closed,
  closure,
  fakeVNC,
  nextMessage,
  startWithDesktop as start,
  writeDesktopConfig
} from "./vnc-test-support.js"

const connected = async (socketUrl: () => string) => {
  const socket = new WebSocket(socketUrl())
  expect((await nextMessage(socket)).toString()).toBe("RFB 003.008\n")
  return socket
}

describe("a viewer that is already connected", () => {
  it("is disconnected, with the reason, once the desktop is removed", async () => {
    const vnc = await fakeVNC()
    const { socketUrl, dataDir, desktops } = await start({ socket: vnc.socket })
    const socket = await connected(socketUrl)
    const ended = closure(socket)
    const upstream = vnc.connections[0]!
    const hungUp = new Promise<void>((resolve) => upstream.once("close", () => resolve()))

    rmSync(join(dataDir, SCREEN_SHARING_CONFIG_FILE))
    desktops.relays?.recheck()
    expect(await ended).toEqual({ code: 1011, reason: "The desktop on this machine was removed." })
    await hungUp
  })

  it("is disconnected once the desktop's socket stops being private", async () => {
    const vnc = await fakeVNC()
    const { socketUrl, desktops } = await start({ socket: vnc.socket })
    const socket = await connected(socketUrl)
    const ended = closure(socket)

    chmodSync(vnc.socket, 0o666)
    desktops.relays?.recheck()
    expect(await ended).toEqual({
      code: 1011,
      reason: "Other accounts on this machine can reach its desktop, so Codevisor won't share it."
    })
  })

  it("is disconnected when the config now names another desktop", async () => {
    const vnc = await fakeVNC()
    const other = await fakeVNC()
    const { socketUrl, dataDir, desktops } = await start({ socket: vnc.socket })
    const socket = await connected(socketUrl)
    const ended = closure(socket)

    writeDesktopConfig(dataDir, { socket: other.socket })
    desktops.relays?.recheck()
    expect((await ended).reason).toBe("The desktop on this machine was removed.")
  })

  it("keeps streaming while the desktop is still shared", async () => {
    const vnc = await fakeVNC()
    const { socketUrl, desktops } = await start({ socket: vnc.socket })
    const socket = await connected(socketUrl)

    desktops.relays?.recheck()
    const echoed = nextMessage(socket)
    socket.send(Buffer.from([0x52, 0x46, 0x42]))
    expect([...(await echoed)]).toEqual([0x52, 0x46, 0x42])
    const done = closed(socket)
    socket.close()
    await done
  })
})

it("cuts a withdrawn viewer off at once: its link to the desktop, its control seat and its messages", () => {
  const closes: Array<[number, string]> = []
  const webSocket = Object.assign(new EventEmitter(), {
    bufferedAmount: 0,
    readyState: WebSocket.OPEN,
    close: (code: number, reason: string) => void closes.push([code, reason]),
    send: () => undefined
  })
  const upstream = new Socket()
  const written = vi.spyOn(upstream, "write")
  const client = new Socket()
  const relays = new VNCRelays(() => "The desktop on this machine was removed.")
  const arbiter = new VNCControlArbiter()
  const left = vi.spyOn(arbiter, "leave")
  const received = vi.spyOn(arbiter, "receive")
  const config = { socket: "/run/user/1000/codevisor-desktop.sock", name: "Desktop" }
  try {
    spliceVNCSocket(
      config,
      new URL(`http://localhost/?displayId=${VNC_DISPLAY_ID}`),
      new IncomingMessage(client),
      client,
      Buffer.alloc(0),
      { handleUpgrade: (_request, _socket, _head, done) => done(webSocket) },
      {
        dial: () => upstream,
        arbiter,
        locate: (path) => ({ path }),
        relays
      }
    )
    relays.recheck()
    expect(closes).toEqual([[1011, "The desktop on this machine was removed."]])
    expect(upstream.destroyed).toBe(true)
    expect(left).toHaveBeenCalledOnce()

    written.mockClear()
    webSocket.emit("message", Buffer.from("RFB 003.008\n", "latin1"), true)
    webSocket.emit("message", Buffer.from('{"type":"request","name":"Studio"}'), false)
    expect(written).not.toHaveBeenCalled()
    expect(received).not.toHaveBeenCalled()
  } finally {
    written.mockRestore()
    upstream.destroy()
    client.destroy()
  }
})

it("tells the screen a viewer has joined only once the connection to its VNC server is made", () => {
  const webSocket = Object.assign(new EventEmitter(), {
    bufferedAmount: 0,
    readyState: WebSocket.OPEN,
    close: () => undefined,
    send: () => undefined
  })
  const upstream = new Socket()
  const client = new Socket()
  const joined: string[] = []
  const screen = {
    socket: "/run/user/1000/codevisor-screen.sock",
    name: "Screen",
    screen: true as const
  }
  try {
    spliceVNCSocket(
      screen,
      new URL(`http://localhost/?displayId=${VNC_SCREEN_ID}`),
      new IncomingMessage(client),
      client,
      Buffer.alloc(0),
      { handleUpgrade: (_request, _socket, _head, done) => done(webSocket) },
      {
        dial: () => upstream,
        arbiter: new VNCControlArbiter(),
        locate: (path) => ({ path }),
        viewerJoined: (display) => void joined.push(display.name)
      }
    )
    expect(joined).toEqual([])

    upstream.emit("connect")
    expect(joined).toEqual(["Screen"])
  } finally {
    upstream.destroy()
    client.destroy()
  }
})
