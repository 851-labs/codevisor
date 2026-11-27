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

const setUpDesktop = (dataDir: string, display: number): void =>
  writeFileSync(
    configPath(dataDir),
    JSON.stringify({
      vnc: {
        socket: "/run/user/1000/codevisor-desktop.sock",
        display,
        xauthority: "/run/user/1000/codevisor-desktop.xauth",
        name: "Desktop",
        desktop: "xfce"
      },
      service: "systemd-user"
    })
  )

const shell = { PATH: "/usr/bin", HOME: "/home/codevisor" }

describe("the desktop's display for what the server starts", () => {
  it("adds the display and cookie of a desktop Codevisor set up", () => {
    const dataDir = dataFolder()
    setUpDesktop(dataDir, 1)

    expect(desktopEnvironment({ dataDir, platform: "linux" })(shell)).toEqual({
      ...shell,
      DISPLAY: ":1",
      XAUTHORITY: "/run/user/1000/codevisor-desktop.xauth"
    })
  })

  it("reads the config each time, so a desktop that appears, moves or goes is followed", () => {
    const dataDir = dataFolder()
    const withDesktop = desktopEnvironment({ dataDir, platform: "linux" })
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
    ["a Wayland display", { WAYLAND_DISPLAY: "wayland-0" }]
  ])("leaves an environment that already has %s as it is", (_name, display) => {
    const dataDir = dataFolder()
    setUpDesktop(dataDir, 1)
    const env = { ...shell, ...display }

    expect(desktopEnvironment({ dataDir, platform: "linux" })(env)).toEqual(env)
  })

  it("replaces a cookie that came without a display, because the pair belongs together", () => {
    const dataDir = dataFolder()
    setUpDesktop(dataDir, 1)
    const env = { ...shell, XAUTHORITY: "/home/codevisor/.Xauthority" }

    expect(desktopEnvironment({ dataDir, platform: "linux" })(env)).toMatchObject({
      DISPLAY: ":1",
      XAUTHORITY: "/run/user/1000/codevisor-desktop.xauth"
    })
  })

  it.each([
    [
      "a desktop someone else set up",
      JSON.stringify({
        vnc: { socket: "/tmp/runtime-root/desktop.sock", display: 1, xauthority: "/tmp/x.auth" },
        devContainerDesktop: true
      })
    ],
    [
      "a desktop from an older Codevisor, on a port",
      JSON.stringify({ vnc: { port: 5901, display: 1 }, service: "systemd-user" })
    ],
    [
      "a desktop with no display number",
      JSON.stringify({ vnc: { socket: "/run/user/1000/desktop.sock" }, service: "process" })
    ],
    ["a config that can't be read", "{ not json"]
  ])("adds nothing for %s", (_name, config) => {
    const dataDir = dataFolder()
    writeFileSync(configPath(dataDir), config)

    expect(desktopEnvironment({ dataDir, platform: "linux" })(shell)).toEqual(shell)
  })

  it("adds nothing on a Mac, whatever the data folder holds", () => {
    const dataDir = dataFolder()
    setUpDesktop(dataDir, 1)

    expect(desktopEnvironment({ dataDir, platform: "darwin" })(shell)).toEqual(shell)
  })
})
