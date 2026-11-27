import { describe, expect, it } from "vitest"

import type { PrivateSocket } from "../routes/private-socket.js"
import { desktopEnvironment } from "./desktop-environment.js"

const dataDir = "/home/codevisor/.codevisor/data"
const config = `${dataDir}/screen-sharing.json`
const socket = "/run/user/1001/codevisor-desktop.sock"
const cookie = "/run/user/1001/codevisor-desktop.xauth"
const runner = 4243
const runnerCommand = `/opt/node\0/opt/codevisor/cli.js\0desktop\0run\0--data-dir\0${dataDir}\0`

const managed = (display: number): string =>
  JSON.stringify({
    vnc: { socket, display, xauthority: cookie, name: "Desktop", desktop: "xfce" },
    service: "systemd-user"
  })

const linuxMachine = (platform: NodeJS.Platform = "linux") => {
  const files = new Map<string, string>()
  const state = { sessionIsUp: true }
  const system = {
    platform,
    readText: (path: string): string | undefined => files.get(path),
    processAlive: (pid: number): boolean => state.sessionIsUp && pid === runner
  }
  const locate = (configured: string): PrivateSocket =>
    files.has(config) ? { path: configured } : { problem: "missing", detail: "nothing there" }
  const setUpDesktop = (display: number, text = managed(display)): void => {
    files.set(config, text)
    files.set(`${socket}.ready`, `${runner}\n`)
    files.set(`/proc/${runner}/cmdline`, runnerCommand)
  }
  return {
    files,
    setUpDesktop,
    removeDesktop: () => files.delete(config),
    stopSession: () => void (state.sessionIsUp = false),
    withDesktop: desktopEnvironment({ dataDir, system, locate }),
    asAnotherServer: desktopEnvironment({ dataDir: "/home/codevisor/dev/data", system, locate })
  }
}

const shell = { PATH: "/usr/bin", HOME: "/home/codevisor" }
const onDisplay = (display: string) => ({
  DISPLAY: display,
  XAUTHORITY: cookie,
  CODEVISOR_DESKTOP_DISPLAY: display,
  CODEVISOR_DESKTOP_CONFIG: config
})

describe("the desktop's display for what the server starts", () => {
  it("adds the display and cookie of a running desktop Codevisor set up, marked as its own", () => {
    const machine = linuxMachine()
    machine.setUpDesktop(1)

    expect(machine.withDesktop(shell)).toEqual({ ...shell, ...onDisplay(":1") })
  })

  it("reads the config each time, so a desktop that appears, moves or goes is followed", () => {
    const machine = linuxMachine()
    expect(machine.withDesktop(shell)).toEqual(shell)

    machine.setUpDesktop(1)
    expect(machine.withDesktop(shell).DISPLAY).toBe(":1")

    machine.setUpDesktop(4)
    expect(machine.withDesktop(shell).DISPLAY).toBe(":4")

    machine.removeDesktop()
    expect(machine.withDesktop(shell)).toEqual(shell)
  })

  it.each([
    ["a DISPLAY", { DISPLAY: ":0", XAUTHORITY: "/home/codevisor/.Xauthority" }],
    ["a DISPLAY and no cookie", { DISPLAY: ":0" }],
    ["an emptied DISPLAY", { DISPLAY: "" }],
    ["a Wayland display", { WAYLAND_DISPLAY: "wayland-0" }],
    ["a DISPLAY chosen after Codevisor's", { ...onDisplay(":1"), DISPLAY: ":0" }]
  ])("leaves an environment that already has %s as it is", (_name, display) => {
    const machine = linuxMachine()
    machine.setUpDesktop(1)
    const env = { ...shell, ...display }

    expect(machine.withDesktop(env)).toEqual(env)
  })

  it("replaces a cookie that came without a display, because the pair belongs together", () => {
    const machine = linuxMachine()
    machine.setUpDesktop(1)
    const env = { ...shell, XAUTHORITY: "/home/codevisor/.Xauthority" }

    expect(machine.withDesktop(env)).toEqual({ ...shell, ...onDisplay(":1") })
  })

  it("adds nothing while the desktop is set up but not up", () => {
    const machine = linuxMachine()
    machine.setUpDesktop(1)
    machine.stopSession()

    expect(machine.withDesktop(shell)).toEqual(shell)
  })

  describe("in an environment that got its display from this server", () => {
    const inherited = { ...shell, LANG: "C.UTF-8", ...onDisplay(":1") }

    it("follows the desktop to its new display", () => {
      const machine = linuxMachine()
      machine.setUpDesktop(4)

      expect(machine.withDesktop(inherited)).toEqual({
        ...shell,
        LANG: "C.UTF-8",
        ...onDisplay(":4")
      })
    })

    it.each([
      ["removed", (machine: ReturnType<typeof linuxMachine>) => void machine.removeDesktop()],
      ["down", (machine: ReturnType<typeof linuxMachine>) => machine.stopSession()]
    ])("takes the display away once the desktop is %s", (_name, change) => {
      const machine = linuxMachine()
      machine.setUpDesktop(1)
      change(machine)

      expect(machine.withDesktop(inherited)).toEqual({ ...shell, LANG: "C.UTF-8" })
    })

    it("takes it away and adds nothing when a Wayland display is there too", () => {
      const machine = linuxMachine()
      machine.setUpDesktop(1)
      const env = { ...inherited, WAYLAND_DISPLAY: "wayland-0" }

      expect(machine.withDesktop(env)).toEqual({
        ...shell,
        LANG: "C.UTF-8",
        WAYLAND_DISPLAY: "wayland-0"
      })
    })
  })

  describe("in an environment that got its display from another Codevisor server", () => {
    const inherited = { ...shell, ...onDisplay(":1") }

    it("leaves it exactly as it is while this server has no desktop of its own up", () => {
      const machine = linuxMachine()
      machine.setUpDesktop(1)

      expect(machine.asAnotherServer(inherited)).toEqual(inherited)
    })

    it("replaces it with this server's own desktop when that is up", () => {
      const machine = linuxMachine()
      machine.setUpDesktop(4)
      const fromElsewhere = {
        ...inherited,
        CODEVISOR_DESKTOP_CONFIG: "/srv/other/screen-sharing.json"
      }

      expect(machine.withDesktop(fromElsewhere)).toEqual({ ...shell, ...onDisplay(":4") })
    })
  })

  it.each([
    [
      "a desktop someone else set up",
      { vnc: { socket, display: 1, xauthority: cookie }, devContainerDesktop: true }
    ],
    [
      "a desktop from an older Codevisor, on a port",
      { vnc: { port: 5901, display: 1 }, service: "systemd-user" }
    ],
    [
      "a desktop with no display number",
      { vnc: { socket, xauthority: cookie }, service: "process" }
    ],
    ["a desktop with no cookie", { vnc: { socket, display: 1 }, service: "process" }]
  ])("adds nothing for %s, even with a session running", (_name, written) => {
    const machine = linuxMachine()
    machine.setUpDesktop(1, JSON.stringify(written))

    expect(machine.withDesktop(shell)).toEqual(shell)
  })

  it("adds nothing for a config that can't be read", () => {
    const machine = linuxMachine()
    machine.setUpDesktop(1, "{ not json")

    expect(machine.withDesktop(shell)).toEqual(shell)
  })

  it("adds nothing on a Mac, whatever the data folder holds", () => {
    const machine = linuxMachine("darwin")
    machine.setUpDesktop(1)

    expect(machine.withDesktop(shell)).toEqual(shell)
  })
})
