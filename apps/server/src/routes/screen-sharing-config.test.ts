import { describe, expect, it } from "vitest"

import {
  displayEntries,
  displayEntry,
  withDisplayEntry,
  withoutDisplayEntry
} from "./screen-sharing-config.js"
import { desktopSetup, recordedDesktopService, screenSetup } from "./screen-sharing-vnc.js"

const desktopVnc = { socket: "/run/user/1000/codevisor-desktop.sock", display: 1, name: "Desktop" }
const screenVnc = { socket: "/run/user/1000/codevisor-screen.sock", name: "Screen" }
const oneEntry = JSON.stringify({ vnc: desktopVnc, service: "systemd-user" })
const screen = { id: "screen", vnc: screenVnc, service: "server" }

describe("the displays a server's config names", () => {
  it("reads a config with one desktop at the top, as written before there was a list", () => {
    expect(displayEntries(oneEntry)).toEqual([
      { id: "desktop", vnc: desktopVnc, service: "systemd-user" }
    ])
    expect(recordedDesktopService(oneEntry)).toBe("systemd-user")
    expect(desktopSetup(oneEntry)).toMatchObject({ kind: "ready", config: { display: 1 } })
    expect(screenSetup(oneEntry)).toBeUndefined()
  })

  it("adds the screen beside the desktop, desktop first, and reads both back", () => {
    const both = withDisplayEntry(oneEntry, screen)

    expect(JSON.parse(both).displays.map((entry: { id: string }) => entry.id)).toEqual([
      "desktop",
      "screen"
    ])
    expect(desktopSetup(both)).toMatchObject({ kind: "ready", config: { display: 1 } })
    expect(recordedDesktopService(both)).toBe("systemd-user")
    expect(screenSetup(both)).toEqual({ socket: screenVnc.socket, name: "Screen", screen: true })
  })

  it("replaces an entry with the same name and leaves the other one alone", () => {
    const both = withDisplayEntry(oneEntry, screen)
    const moved = { id: "desktop", vnc: { ...desktopVnc, display: 4 }, service: "process" }

    const rewritten = withDisplayEntry(both, moved)

    expect(displayEntry(rewritten, "desktop")).toEqual(moved)
    expect(displayEntry(rewritten, "screen")).toEqual(screen)
  })

  it("carries over what else a config holds, such as the dev container's marker", () => {
    const devContainer = JSON.stringify({ vnc: desktopVnc, devContainerDesktop: true })

    const both = withDisplayEntry(devContainer, screen)
    const back = withoutDisplayEntry(both, "screen")

    expect(JSON.parse(both)).toEqual({
      devContainerDesktop: true,
      displays: [{ id: "desktop", vnc: desktopVnc }, screen]
    })
    expect(JSON.parse(back ?? "")).toEqual({
      devContainerDesktop: true,
      displays: [{ id: "desktop", vnc: desktopVnc }]
    })
  })

  it("keeps what is left when one display is removed, and nothing when it was the last", () => {
    const both = withDisplayEntry(oneEntry, screen)

    expect(displayEntries(withoutDisplayEntry(both, "desktop"))).toEqual([screen])
    expect(withoutDisplayEntry(oneEntry, "desktop")).toBeUndefined()
    expect(withoutDisplayEntry(undefined, "screen")).toBeUndefined()
  })

  it("has no desktop when the list only names the screen", () => {
    const onlyTheScreen = withDisplayEntry(undefined, screen)

    expect(desktopSetup(onlyTheScreen)).toEqual({ kind: "absent" })
    expect(recordedDesktopService(onlyTheScreen)).toBeUndefined()
  })

  it.each([
    ["a screen nobody recorded as Codevisor's", { ...screen, service: undefined }],
    ["a screen without a usable socket", { ...screen, vnc: { socket: "screen.sock" } }]
  ])("doesn't share %s", (_name, entry) => {
    expect(screenSetup(JSON.stringify({ displays: [entry] }))).toBeUndefined()
  })

  it.each([undefined, "", "{ not json", "[]", '{"displays": "many"}', '{"displays": [7, null]}'])(
    "names no displays for a config it can't read: %s",
    (text) => {
      expect(displayEntries(text)).toEqual([])
    }
  )
})
