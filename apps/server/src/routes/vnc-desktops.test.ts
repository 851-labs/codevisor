import { describe, expect, it } from "vitest"

import { VNC_DISPLAY_ID } from "./screen-sharing-vnc.js"
import { fileVNCDesktops } from "./vnc-desktops.js"
import {
  fakeVNC,
  privateDirectory,
  recordingSession,
  writeDesktopConfig
} from "./vnc-test-support.js"

const request = {
  version: 1 as const,
  workspaceId: "w",
  paneId: "p",
  viewerId: "v",
  displayId: VNC_DISPLAY_ID
}

describe("the desktop a server offers from its data folder", () => {
  it("scales an Xfce desktop through that desktop's own display and cookie", async () => {
    const dataDir = privateDirectory()
    writeDesktopConfig(dataDir, {
      socket: "/run/user/1000/codevisor-desktop.sock",
      desktop: "xfce",
      display: 3,
      xauthority: "/run/user/1000/codevisor-desktop.xauth"
    })
    const session = recordingSession()
    const desktop = fileVNCDesktops(dataDir, { commands: session.commands }).current()
    expect(await desktop?.respond({ ...request, operation: "setScale", scale: 2 })).toMatchObject({
      status: "ok"
    })
    expect(new Set(session.environments.map((env) => JSON.stringify(env)))).toEqual(
      new Set([
        JSON.stringify({
          DISPLAY: ":3",
          XAUTHORITY: "/run/user/1000/codevisor-desktop.xauth",
          DBUS_SESSION_BUS_ADDRESS: "unix:path=/run/bus"
        })
      ])
    )
  })

  it("offers 2× only for an Xfce desktop whose X11 display it knows", async () => {
    const vnc = await fakeVNC()
    const capabilitiesWith = async (settings: Record<string, unknown>) => {
      const dataDir = privateDirectory()
      writeDesktopConfig(dataDir, { socket: vnc.socket, ...settings })
      const desktop = fileVNCDesktops(dataDir, { commands: recordingSession().commands }).current()
      return desktop?.respond({ ...request, operation: "capabilities" })
    }
    const scalable = { status: "available", displays: [{ scales: [1, 2] }] }
    const fixed = { status: "available", displays: [{ id: VNC_DISPLAY_ID }] }
    expect(await capabilitiesWith({ desktop: "xfce", display: 1 })).toMatchObject(scalable)
    for (const settings of [{ desktop: "xfce" }, { display: 1 }]) {
      const reply = await capabilitiesWith(settings)
      expect(reply).toMatchObject(fixed)
      expect(reply).not.toHaveProperty("displays.0.scales")
    }
  })
})
