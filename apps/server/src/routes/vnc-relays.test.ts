import { chmodSync, rmSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"
import { WebSocket } from "ws"

import { SCREEN_SHARING_CONFIG_FILE } from "./screen-sharing-vnc.js"
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
