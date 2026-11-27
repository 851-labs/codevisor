import { describe, expect, it } from "vitest"

import { machine, type Process } from "./screen-session-test-support.js"
import { ownGraphicalSession } from "./screen-session.js"

const atTheMonitor = { XDG_SEAT: "seat0", DISPLAY: ":0", XAUTHORITY: "/home/alice/.Xauthority" }
const bus = "unix:path=/run/user/1000/bus"
const onDisplay = (display: string) => ({
  WAYLAND_DISPLAY: display,
  XDG_RUNTIME_DIR: "/run/user/1000"
})
const serving = (display: string) => [`/run/user/1000/${display}.lock`]
const at = (processes: Record<number, Process>, liveDisplays?: ReadonlyArray<string>) =>
  machine({ processes, ...(liveDisplays === undefined ? {} : { liveDisplays }) })

describe("the graphical session the server's account has at the screen", () => {
  it("is found from a process of that account that has a seat and a live display", () => {
    const system = at({ 400: { env: { ...atTheMonitor, HOME: "/home/alice" } } })

    expect(ownGraphicalSession(system)).toEqual({
      kind: "x11",
      process: 400,
      display: ":0",
      env: { DISPLAY: ":0", XAUTHORITY: "/home/alice/.Xauthority" }
    })
  })

  it("takes the session bus along when one of the session's processes has it", () => {
    const system = at({
      400: { env: atTheMonitor },
      401: { env: { ...atTheMonitor, DBUS_SESSION_BUS_ADDRESS: bus } }
    })

    expect(ownGraphicalSession(system)).toMatchObject({
      process: 401,
      env: { DBUS_SESSION_BUS_ADDRESS: bus }
    })
  })

  it.each<[string, Record<number, Process>]>([
    ["another account's session", { 400: { uid: 1001, env: atTheMonitor } }],
    [
      "a login over the network, which has no seat",
      { 400: { env: { DISPLAY: "localhost:10.0" } } }
    ],
    ["a seat with no display, a text console", { 400: { env: { XDG_SEAT: "seat0" } } }],
    [
      "a display Codevisor itself handed out",
      { 400: { env: { ...atTheMonitor, DISPLAY: ":1", CODEVISOR_DESKTOP_DISPLAY: ":1" } } }
    ],
    ["a display whose X server is gone", { 400: { env: { ...atTheMonitor, DISPLAY: ":3" } } }]
  ])("doesn't take %s for it", (_name, processes) => {
    expect(ownGraphicalSession(at(processes))).toBeUndefined()
  })

  it("leaves out the display of Codevisor's own virtual desktop", () => {
    const system = at(
      { 400: { env: { ...atTheMonitor, DISPLAY: ":1" } }, 401: { env: atTheMonitor } },
      ["X0", "X1"]
    )

    expect(ownGraphicalSession(system, { ignoreDisplay: ":1" })?.process).toBe(401)
    expect(ownGraphicalSession(system, { ignoreDisplay: ":0" })?.process).toBe(400)
  })

  it("looks at the process it found last time before searching again", () => {
    const system = at({ 400: { env: atTheMonitor }, 401: { env: atTheMonitor, started: 5 } })

    expect(ownGraphicalSession(system, { lookFirstAt: 400 })?.process).toBe(400)
    expect(ownGraphicalSession(system, { lookFirstAt: 999 })?.process).toBe(401)
  })

  it("prefers the newest process where logind can't say which session is the screen's", () => {
    const system = at(
      {
        400: { env: { ...atTheMonitor, DISPLAY: ":1" }, started: 900 },
        401: { env: atTheMonitor, started: 100 }
      },
      ["X0", "X1"]
    )

    expect(ownGraphicalSession(system)?.display).toBe(":1")
  })

  it("takes the display who reported where logind can't be asked, with or without a seat", () => {
    const noSeat = { DISPLAY: ":0", XAUTHORITY: "/home/alice/.Xauthority" }
    const system = at(
      { 400: { env: { ...noSeat, DISPLAY: ":1" }, started: 900 }, 401: { env: noSeat } },
      ["X0", "X1"]
    )

    expect(ownGraphicalSession(system, { display: ":0" })?.process).toBe(401)
    expect(ownGraphicalSession(system, { display: ":2" })).toBeUndefined()
  })

  describe("when logind names the session at the screen", () => {
    const leftOver = { env: atTheMonitor, session: "4", started: 50 }
    const newSession = { env: { ...atTheMonitor, DISPLAY: ":1" }, session: "9", started: 10 }

    it("takes only that session's processes, not one left over from the last login", () => {
      const system = at({ 400: leftOver, 500: newSession }, ["X0", "X1"])

      expect(ownGraphicalSession(system, { session: "9", display: ":1" })).toMatchObject({
        process: 500,
        display: ":1"
      })
    })

    it("uses logind's display even where the processes carry none, and skips ones showing another", () => {
      const system = at({
        500: { env: { ...atTheMonitor, DISPLAY: ":4" }, session: "9" },
        501: { env: { WAYLAND_DISPLAY: "wayland-0", DBUS_SESSION_BUS_ADDRESS: bus }, session: "9" }
      })

      expect(ownGraphicalSession(system, { session: "9", display: ":0" })).toMatchObject({
        process: 501,
        display: ":0",
        env: { DISPLAY: ":0" }
      })
    })

    it("takes a process whose display names a screen of logind's display, as :0.0 does", () => {
      const system = at({ 500: { env: { ...atTheMonitor, DISPLAY: ":0.0" }, session: "9" } })

      expect(ownGraphicalSession(system, { session: "9", display: ":0" })).toMatchObject({
        process: 500,
        display: ":0"
      })
    })

    it("finds nothing when no process of that session is left", () => {
      expect(ownGraphicalSession(at({ 400: leftOver }), { session: "9" })).toBeUndefined()
    })
  })

  it.each([
    ["wlroots", "sway"],
    ["wlroots", "Hyprland"],
    ["wlroots", "labwc"],
    ["wayland", "gnome-shell"],
    ["wayland", "kwin_wayland"]
  ])("calls a Wayland session %s when its compositor is %s", (kind, comm) => {
    const system = at({
      400: { env: { ...onDisplay("wayland-1"), DBUS_SESSION_BUS_ADDRESS: bus }, session: "9" },
      401: { comm, fds: serving("wayland-1") }
    })

    expect(ownGraphicalSession(system, { session: "9" })?.kind).toBe(kind)
  })

  it("finds the compositor by its display alone, also when an app's parent is not the compositor", () => {
    const system = at({
      400: { env: onDisplay("wayland-1"), session: "9" },
      401: { comm: "sway", fds: ["/dev/null", "/run/user/1000/wayland-2.lock"] },
      402: { comm: "river", fds: ["/dev/null", ...serving("wayland-1")] }
    })

    expect(ownGraphicalSession(system, { session: "9" })?.kind).toBe("wlroots")
  })

  it("doesn't take a compositor that serves another display, or another account's, for the session's", () => {
    const system = at({
      400: { env: onDisplay("wayland-1"), session: "9" },
      401: { comm: "sway", fds: serving("wayland-2") },
      402: { comm: "sway", uid: 1001, fds: serving("wayland-1") }
    })

    expect(ownGraphicalSession(system, { session: "9" })?.kind).toBe("wayland")
  })

  it("calls a GNOME session Wayland and shares its own display, even with a Sway window nested in it", () => {
    const outer = { ...onDisplay("wayland-0"), DBUS_SESSION_BUS_ADDRESS: bus }
    const nested = { ...onDisplay("wayland-1"), DBUS_SESSION_BUS_ADDRESS: bus }
    const system = at({
      300: { comm: "gnome-shell", fds: serving("wayland-0") },
      400: { env: outer, session: "9", started: 2 },
      401: { env: outer, comm: "sway", session: "9", fds: serving("wayland-1"), started: 3 },
      402: { env: nested, session: "9", started: 5 }
    })

    expect(ownGraphicalSession(system, { session: "9", type: "wayland" })).toMatchObject({
      kind: "wayland",
      env: { WAYLAND_DISPLAY: "wayland-0" }
    })
  })

  it("takes a Wayland session's Wayland processes even when only XWayland apps have the bus", () => {
    const system = at({
      400: { env: onDisplay("wayland-1"), session: "9" },
      401: { comm: "sway", fds: serving("wayland-1") },
      402: { env: { DISPLAY: ":0", DBUS_SESSION_BUS_ADDRESS: bus }, session: "9" }
    })

    expect(ownGraphicalSession(system, { session: "9", type: "wayland" })).toMatchObject({
      kind: "wlroots",
      process: 400
    })
  })

  it("doesn't put Wayland processes first in a session logind doesn't call Wayland", () => {
    const system = at({
      400: { env: atTheMonitor, started: 5 },
      401: { env: { ...atTheMonitor, ...onDisplay("wayland-1") }, started: 1 },
      402: { comm: "sway", fds: serving("wayland-1") }
    })

    expect(ownGraphicalSession(system, { display: ":0" })).toMatchObject({
      kind: "x11",
      process: 400
    })
  })

  it("takes a Wayland session's Wayland processes over a newer app started for XWayland alone", () => {
    const wayland = { ...onDisplay("wayland-1"), DBUS_SESSION_BUS_ADDRESS: bus }
    const xwaylandOnly = { DISPLAY: ":0", DBUS_SESSION_BUS_ADDRESS: bus }
    const system = at({
      400: { env: wayland, session: "9", started: 1 },
      401: { comm: "sway", fds: serving("wayland-1") },
      402: { env: xwaylandOnly, session: "9", started: 5 }
    })

    expect(ownGraphicalSession(system, { session: "9", type: "wayland" })).toMatchObject({
      kind: "wlroots",
      process: 400
    })
    expect(
      ownGraphicalSession(system, { session: "9", type: "wayland", lookFirstAt: 402 })?.process
    ).toBe(400)
  })

  it("without logind, finds the compositor the same way", () => {
    const seated = { XDG_SEAT: "seat0", ...onDisplay("wayland-1") }
    const labwc = at({ 400: { env: seated }, 300: { comm: "labwc", fds: serving("wayland-1") } })
    const swayElsewhere = at({ 400: { env: seated }, 500: { comm: "sway" } })

    expect(ownGraphicalSession(labwc)?.kind).toBe("wlroots")
    expect(ownGraphicalSession(swayElsewhere)?.kind).toBe("wayland")
  })

  it("finds the lock of a display given as a path", () => {
    const system = at({
      400: { env: { XDG_SEAT: "seat0", WAYLAND_DISPLAY: "/tmp/sway/wayland-1" } },
      401: { comm: "sway", fds: ["/tmp/sway/wayland-1.lock"] }
    })

    expect(ownGraphicalSession(system)?.kind).toBe("wlroots")
  })

  it.each([
    ["wlroots", { SWAYSOCK: "/run/user/1000/sway-ipc.sock" }],
    ["wlroots", { HYPRLAND_INSTANCE_SIGNATURE: "abc" }],
    ["wayland", {}]
  ])("tells a %s session from an X11 one", (kind, marks) => {
    const system = at({
      400: { env: { XDG_SEAT: "seat0", WAYLAND_DISPLAY: "wayland-1", DISPLAY: ":0", ...marks } }
    })

    expect(ownGraphicalSession(system)?.kind).toBe(kind)
  })
})
