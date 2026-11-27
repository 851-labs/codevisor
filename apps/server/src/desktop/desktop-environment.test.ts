import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { tempDirs } from "../test-support.js"
import { desktopEnvironment } from "./desktop-environment.js"

const dataFolder = (): string => {
  const dataDir = mkdtempSync(join(tmpdir(), "codevisor-desktop-env-"))
  tempDirs.push(dataDir)
  return dataDir
}

const configPath = (dataDir: string): string => join(dataDir, "screen-sharing.json")
const socketPath = (dataDir: string): string => join(dataDir, "codevisor-desktop.sock")
const cookiePath = (dataDir: string): string => join(dataDir, "codevisor-desktop.xauth")
const readyMark = (dataDir: string): string => `${socketPath(dataDir)}.ready`

const noSuchProcess = 2_147_483_646

const sessionRunBy = (dataDir: string, runner: number): void =>
  writeFileSync(readyMark(dataDir), `${runner}\n`)

const setUpDesktop = (dataDir: string, display: number): void => {
  const vnc = {
    socket: socketPath(dataDir),
    display,
    xauthority: cookiePath(dataDir),
    name: "Desktop",
    desktop: "xfce"
  }
  writeFileSync(configPath(dataDir), JSON.stringify({ vnc, service: "systemd-user" }))
  sessionRunBy(dataDir, process.pid)
}

const onLinux = (dataDir: string) => desktopEnvironment({ dataDir, platform: "linux" })

const shell = { PATH: "/usr/bin", HOME: "/home/codevisor" }

const inherited = (dataDir: string) => onLinux(dataDir)({ ...shell, LANG: "C.UTF-8" })

describe("the desktop's display for what the server starts", () => {
  it("adds the display and cookie of a running desktop Codevisor set up", () => {
    const dataDir = dataFolder()
    setUpDesktop(dataDir, 1)

    expect(onLinux(dataDir)(shell)).toEqual({
      ...shell,
      DISPLAY: ":1",
      XAUTHORITY: cookiePath(dataDir),
      CODEVISOR_DESKTOP_DISPLAY: ":1"
    })
  })

  it("reads the config each time, so a desktop that appears, moves or goes is followed", () => {
    const dataDir = dataFolder()
    const withDesktop = onLinux(dataDir)
    expect(withDesktop(shell)).toEqual(shell)

    setUpDesktop(dataDir, 1)
    expect(withDesktop(shell).DISPLAY).toBe(":1")

    setUpDesktop(dataDir, 4)
    expect(withDesktop(shell).DISPLAY).toBe(":4")

    rmSync(configPath(dataDir))
    expect(withDesktop(shell)).toEqual(shell)
  })

  it.each([
    ["a DISPLAY", { DISPLAY: ":0", XAUTHORITY: "/home/codevisor/.Xauthority" }],
    ["a DISPLAY and no cookie", { DISPLAY: ":0" }],
    ["an emptied DISPLAY", { DISPLAY: "" }],
    ["a Wayland display", { WAYLAND_DISPLAY: "wayland-0" }],
    ["a DISPLAY chosen after Codevisor's", { DISPLAY: ":0", CODEVISOR_DESKTOP_DISPLAY: ":1" }]
  ])("leaves an environment that already has %s as it is", (_name, display) => {
    const dataDir = dataFolder()
    setUpDesktop(dataDir, 1)
    const env = { ...shell, ...display }

    expect(onLinux(dataDir)(env)).toEqual(env)
  })

  it("replaces a cookie that came without a display, because the pair belongs together", () => {
    const dataDir = dataFolder()
    setUpDesktop(dataDir, 1)
    const env = { ...shell, XAUTHORITY: "/home/codevisor/.Xauthority" }

    expect(onLinux(dataDir)(env)).toMatchObject({
      DISPLAY: ":1",
      XAUTHORITY: cookiePath(dataDir)
    })
  })

  describe("in an environment that got its display from Codevisor", () => {
    it("follows the desktop to its new display", () => {
      const dataDir = dataFolder()
      setUpDesktop(dataDir, 1)
      const fromATerminal = inherited(dataDir)

      setUpDesktop(dataDir, 4)

      expect(onLinux(dataDir)(fromATerminal)).toEqual({
        ...shell,
        LANG: "C.UTF-8",
        DISPLAY: ":4",
        XAUTHORITY: cookiePath(dataDir),
        CODEVISOR_DESKTOP_DISPLAY: ":4"
      })
    })

    it("takes the display away again once the desktop is removed", () => {
      const dataDir = dataFolder()
      setUpDesktop(dataDir, 1)
      const fromATerminal = inherited(dataDir)

      rmSync(configPath(dataDir))

      expect(onLinux(dataDir)(fromATerminal)).toEqual({ ...shell, LANG: "C.UTF-8" })
    })
  })

  it.each([
    ["has no session running", (dataDir: string) => rmSync(readyMark(dataDir))],
    ["was left by a runner that is gone", (dataDir: string) => sessionRunBy(dataDir, noSuchProcess)]
  ])("adds nothing while the desktop %s", (_name, stop) => {
    const dataDir = dataFolder()
    setUpDesktop(dataDir, 1)
    stop(dataDir)

    expect(onLinux(dataDir)(shell)).toEqual(shell)
  })

  it.each([
    [
      "a desktop someone else set up",
      (dataDir: string) => ({
        vnc: { socket: socketPath(dataDir), display: 1, xauthority: cookiePath(dataDir) },
        devContainerDesktop: true
      })
    ],
    [
      "a desktop from an older Codevisor, on a port",
      () => ({ vnc: { port: 5901, display: 1 }, service: "systemd-user" })
    ],
    [
      "a desktop with no display number",
      (dataDir: string) => ({
        vnc: { socket: socketPath(dataDir), xauthority: cookiePath(dataDir) },
        service: "process"
      })
    ],
    [
      "a desktop with no cookie",
      (dataDir: string) => ({
        vnc: { socket: socketPath(dataDir), display: 1 },
        service: "process"
      })
    ]
  ])("adds nothing for %s, even with a session running", (_name, config) => {
    const dataDir = dataFolder()
    writeFileSync(configPath(dataDir), JSON.stringify(config(dataDir)))
    sessionRunBy(dataDir, process.pid)

    expect(onLinux(dataDir)(shell)).toEqual(shell)
  })

  it("adds nothing for a config that can't be read", () => {
    const dataDir = dataFolder()
    writeFileSync(configPath(dataDir), "{ not json")

    expect(onLinux(dataDir)(shell)).toEqual(shell)
  })

  it("adds nothing on a Mac, whatever the data folder holds", () => {
    const dataDir = dataFolder()
    setUpDesktop(dataDir, 1)

    expect(desktopEnvironment({ dataDir, platform: "darwin" })(shell)).toEqual(shell)
  })
})
