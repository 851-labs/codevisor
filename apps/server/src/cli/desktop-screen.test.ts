import type { ScreenStatus } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { screenRemoveCommand, screenSetupCommand } from "./desktop-screen.js"
import {
  answers,
  apt,
  aptUpdateShown,
  running,
  status,
  url,
  world
} from "./desktop-test-support.js"
import { desktopStatusCommand } from "./desktop.js"

const screen = (changes: Partial<ScreenStatus> = {}): ScreenStatus => ({
  state: "none",
  missing: [],
  others: [],
  ...changes
})
const loggedIn = { session: "x11", display: ":0" }
const withScreen = (changes: Partial<ScreenStatus> = {}) => status({ screen: screen(changes) })
const shared = withScreen({ state: "running", ...loggedIn })
const missing = ["x0vncserver", "notify-send"]
const aptInstallForTheScreen = `${apt} install -y -q --no-install-recommends tigervnc-scraping-server libnotify-bin`

describe("codevisor desktop setup --screen", () => {
  it("shares the screen its account is logged in at", async () => {
    const machine = world({
      [`GET ${url("?screen=1")}`]: answers(withScreen(loggedIn)),
      [`POST ${url("/screen")}`]: answers(shared)
    })

    expect(await screenSetupCommand(machine.deps)).toBe(0)
    expect(machine.logs).toEqual([
      "==> Checking this machine",
      "    Ubuntu 24.04.5 LTS, codevisor is logged in at this machine's screen (X11, display :0)",
      "==> The screen is shared. Open this machine in Codevisor and choose the display named Screen."
    ])
  })

  it("sets it up for later when nobody is logged in", async () => {
    const machine = world({
      [`GET ${url("?screen=1")}`]: answers(withScreen()),
      [`POST ${url("/screen")}`]: answers(withScreen({ state: "waiting" }))
    })

    expect(await screenSetupCommand(machine.deps)).toBe(0)
    expect(machine.logs.slice(1)).toEqual([
      "    Ubuntu 24.04.5 LTS, nobody is logged in at this machine's screen",
      "==> Set up. The screen is shared whenever codevisor is logged in at this machine, and nobody is right now."
    ])
  })

  it("refuses in one sentence when someone else is at the screen, and asks the server for nothing", async () => {
    const machine = world({
      [`GET ${url("?screen=1")}`]: answers(withScreen({ others: ["alice"] }))
    })

    expect(await screenSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "alice is logged in at this machine's screen, and Codevisor runs as codevisor here, so it can't share that screen. Set up a separate desktop instead: codevisor desktop setup"
    ])
    expect(machine.httpCalls(`POST ${url("/screen")}`)).toBe(0)
  })

  it("has the server install what is missing when its account needs no sudo password, and waits for it", async () => {
    const toInstall = withScreen({ ...loggedIn, missing, sudo: "passwordless" })
    const installing = withScreen({ ...loggedIn, missing, busy: "Installing packages" })
    const machine = world({
      [`GET ${url("?screen=1")}`]: answers(toInstall),
      [`GET ${url()}`]: answers(installing, withScreen(loggedIn)),
      [`POST ${url("/screen/packages")}`]: answers(installing),
      [`POST ${url("/screen")}`]: answers(shared)
    })

    expect(await screenSetupCommand(machine.deps)).toBe(0)
    expect(machine.logs[2]).toBe("==> Installing x0vncserver and notify-send with apt")
    expect(machine.httpCalls(`GET ${url()}`)).toBe(2)
    expect(machine.interactiveCalls).toEqual([])
  })

  it("goes by the screen's own install, whatever an earlier desktop install left behind", async () => {
    const earlier = { failure: "Installing packages failed:\nE: Unable to locate package xfce4" }
    const toInstall = { ...withScreen({ ...loggedIn, missing, sudo: "passwordless" }), ...earlier }
    const installed = { ...withScreen(loggedIn), ...earlier }
    const machine = world({
      [`GET ${url("?screen=1")}`]: answers(toInstall),
      [`POST ${url("/screen/packages")}`]: answers(installed),
      [`POST ${url("/screen")}`]: answers(shared)
    })

    expect(await screenSetupCommand(machine.deps)).toBe(0)
    expect(machine.errors).toEqual([])
  })

  it("passes on why the screen's install failed", async () => {
    const failure =
      "Installing packages failed:\nE: Unable to locate package tigervnc-scraping-server"
    const machine = world({
      [`GET ${url("?screen=1")}`]: answers(
        withScreen({ ...loggedIn, missing, sudo: "passwordless" })
      ),
      [`POST ${url("/screen/packages")}`]: answers(withScreen({ ...loggedIn, missing, failure }))
    })

    expect(await screenSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "Installing packages failed:\n    | E: Unable to locate package tigervnc-scraping-server"
    ])
    expect(machine.httpCalls(`POST ${url("/screen")}`)).toBe(0)
  })

  it("runs the install itself with sudo when the account needs a password, from its own package list", async () => {
    const needsPassword = withScreen({ ...loggedIn, missing, sudo: "password" })
    const machine = world({
      [`GET ${url("?screen=1")}`]: answers(needsPassword),
      [`GET ${url()}`]: answers(withScreen(loggedIn)),
      [`POST ${url("/screen")}`]: answers(shared)
    })

    expect(await screenSetupCommand(machine.deps)).toBe(0)
    expect(machine.logs).toContain(`    sudo ${aptUpdateShown}`)
    expect(machine.logs).toContain(`    sudo ${aptInstallForTheScreen}`)
    expect(machine.httpCalls(`POST ${url("/screen/packages")}`)).toBe(0)
  })

  it("names the screen's own command to run again when an administrator has to install", async () => {
    const machine = world(
      { [`GET ${url("?screen=1")}`]: answers(withScreen({ ...loggedIn, missing, sudo: "none" })) },
      { interactive: false }
    )

    expect(await screenSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors[0]).toBe("Installing packages needs an administrator. Ask one to run:")
    expect(machine.errors.at(-1)).toBe("then run `codevisor desktop setup --screen` again.")
  })

  it("refuses a Wayland desktop it can't share before installing anything", async () => {
    const machine = world({
      [`GET ${url("?screen=1")}`]: answers(
        withScreen({ session: "wayland", missing, sudo: "passwordless" })
      )
    })

    expect(await screenSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "This account's session at the screen runs a Wayland desktop that Codevisor can't share yet; it shares X11 sessions and wlroots ones such as Sway and Hyprland."
    ])
    expect(machine.httpCalls(`POST ${url("/screen/packages")}`)).toBe(0)
  })

  it("installs wayvnc for a wlroots session, and shares it", async () => {
    const onSway = { session: "wlroots", display: "wayland-1" }
    const machine = world({
      [`GET ${url("?screen=1")}`]: answers(
        withScreen({ ...onSway, missing: ["wayvnc", "notify-send"], sudo: "password" })
      ),
      [`GET ${url()}`]: answers(withScreen(onSway)),
      [`POST ${url("/screen")}`]: answers(withScreen({ state: "running", ...onSway }))
    })

    expect(await screenSetupCommand(machine.deps)).toBe(0)
    expect(machine.logs).toContain(
      "    Ubuntu 24.04.5 LTS, codevisor is logged in at this machine's screen (Wayland, display wayland-1)"
    )
    expect(machine.logs).toContain(
      `    sudo ${apt} install -y -q --no-install-recommends wayvnc libnotify-bin`
    )
  })

  it("says the screen is set up and will be tried again when it isn't shared yet, and how to undo it", async () => {
    const problem = "x0vncserver didn't open its socket (see /home/codevisor/screen.log)"
    const machine = world({
      [`GET ${url("?screen=1")}`]: answers(withScreen(loggedIn)),
      [`POST ${url("/screen")}`]: answers(withScreen({ state: "stopped", ...loggedIn, problem }))
    })

    expect(await screenSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      `The screen is set up, but isn't shared yet: ${problem}.`,
      "Codevisor tries again every 30 seconds. To undo the setup: codevisor desktop remove --screen"
    ])
  })

  it("says to update a server that doesn't know about screens", async () => {
    const machine = world({ [`GET ${url("?screen=1")}`]: answers(status()) })

    expect(await screenSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "Codevisor on this machine is too old to share its screen. Update it, then run this again."
    ])
  })
})

describe("codevisor desktop remove --screen", () => {
  it("stops sharing the screen and leaves the desktop alone", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(shared),
      [`DELETE ${url("/screen")}`]: answers(withScreen(loggedIn))
    })

    expect(await screenRemoveCommand(machine.deps)).toBe(0)
    expect(machine.logs).toEqual(["The screen is no longer shared. Nothing on it was closed."])
    expect(machine.httpCalls(`DELETE ${url()}`)).toBe(0)
  })

  it("says so when the screen wasn't shared", async () => {
    const machine = world({ [`GET ${url()}`]: answers(withScreen()) })

    expect(await screenRemoveCommand(machine.deps)).toBe(0)
    expect(machine.logs).toEqual(["This machine's screen isn't shared."])
  })
})

const statusLines = async (found: ReturnType<typeof status>) => {
  const machine = world({ [`GET ${url()}`]: answers(found) })
  await desktopStatusCommand(machine.deps)
  return machine.logs
}

describe("codevisor desktop status, about the screen", () => {
  it.each([
    [
      { state: "running" as const, ...loggedIn },
      "The screen (X11, display :0) is shared as codevisor."
    ],
    [
      { state: "waiting" as const },
      "The screen is set up to be shared, but codevisor isn't logged in at it."
    ],
    [
      { state: "waiting" as const, others: ["alice"] },
      "The screen is set up to be shared, but codevisor isn't logged in at it (alice is)."
    ],
    [
      {
        state: "stopped" as const,
        ...loggedIn,
        problem: "the helper that shares the screen isn't running"
      },
      "The screen is set up to be shared but isn't: the helper that shares the screen isn't running"
    ],
    [
      { state: "none" as const, session: "wayland" },
      "This machine's screen isn't shared. This account's session at the screen runs a Wayland desktop that Codevisor can't share yet; it shares X11 sessions and wlroots ones such as Sway and Hyprland."
    ],
    [
      { state: "none" as const, ...loggedIn },
      "This machine's screen isn't shared. Share it with: codevisor desktop setup --screen"
    ],
    [
      { state: "running" as const, session: "constructor", display: ":0" },
      "The screen (display :0) is shared as codevisor."
    ]
  ])("adds a line for the screen: %j", async (found, line) => {
    expect((await statusLines({ ...running, screen: screen(found) })).at(-1)).toBe(line)
  })

  it("says nothing about a screen nobody could share", async () => {
    const withoutAScreen = await statusLines(running)

    expect(await statusLines({ ...running, screen: screen() })).toEqual(withoutAScreen)
  })

  it("prints only what it can vouch for from the server's answer about the screen", async () => {
    const hostile = screen({
      state: "waiting",
      others: ["alice", "mallory\u001b[2J; rm -rf /"],
      problem: "ignored"
    })

    expect((await statusLines({ ...running, screen: hostile })).at(-1)).toBe(
      "The screen is set up to be shared, but codevisor isn't logged in at it (alice is)."
    )
  })
})
