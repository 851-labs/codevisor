import type { DesktopStatus } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import {
  type DesktopCliDeps,
  desktopRemoveCommand,
  desktopSetupCommand,
  desktopStatusCommand
} from "./desktop.js"
import { type FakeOptions, makeWorld } from "./support-test-support.js"

const url = (path = "") => `http://127.0.0.1:49361/v1/desktop${path}`
const install = [
  ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "update", "-q"],
  ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "xfce4"]
]
const missing = ["Xvnc", "startxfce4"]

const status = (changes: Partial<DesktopStatus> = {}): DesktopStatus => ({
  state: "none",
  account: "codevisor",
  system: "Ubuntu 24.04.5 LTS",
  missing: [],
  sudo: "passwordless",
  startsAtBoot: true,
  logHint: "journalctl --user -u codevisor-desktop",
  ...changes
})

const answers = (...bodies: DesktopStatus[]) => bodies.map((body) => ({ status: 200, body }))
const running = status({ state: "running", display: 1, managed: true })

const world = (
  http: FakeOptions["http"],
  terminal: { interactive?: boolean; agrees?: boolean; isRoot?: boolean } = {}
) => {
  const fake = makeWorld({ http: http ?? {}, isRoot: terminal.isRoot ?? false })
  const questions: string[] = []
  const deps: DesktopCliDeps = {
    ...fake.deps,
    isInteractive: terminal.interactive ?? true,
    confirm: async (question) => {
      questions.push(question)
      return terminal.agrees ?? true
    }
  }
  return { ...fake, deps, questions }
}

describe("codevisor desktop setup", () => {
  it("has the server install and start everything when its account needs no sudo password", async () => {
    const busy = "Installing packages"
    const machine = world({
      [`GET ${url()}`]: answers(
        status({ missing, install }),
        status({ missing, install, busy }),
        status({ install })
      ),
      [`POST ${url("/packages")}`]: answers(status({ missing, install, busy })),
      [`POST ${url("/start")}`]: answers(running)
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.httpCalls(`GET ${url()}`)).toBe(3)
    expect(machine.logs).toEqual([
      "==> Checking this machine",
      "    Ubuntu 24.04.5 LTS, no desktop set up",
      "==> Installing Xfce and TigerVNC (about 640 MB)",
      "==> Starting the desktop as codevisor",
      "==> The desktop is ready. Open it from this machine in Codevisor."
    ])
    expect(machine.interactiveCalls).toEqual([])
    expect(machine.httpCalls(`POST ${url("/packages")}`)).toBe(1)
  })

  it("waits for the server's install, and passes on why it failed", async () => {
    const failure = "Installing packages failed:\nE: Unable to locate package xfce4"
    const machine = world({
      [`GET ${url()}`]: answers(
        status({ missing, install }),
        status({ missing, install, failure })
      ),
      [`POST ${url("/packages")}`]: answers(
        status({ missing, install, busy: "Installing packages" })
      )
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([failure])
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(0)
  })

  it("keeps waiting through a few unanswered checks during the install", async () => {
    const busy = "Installing packages"
    const machine = world({
      [`GET ${url()}`]: [
        ...answers(status({ missing, install })),
        undefined,
        undefined,
        ...answers(status({ install }))
      ],
      [`POST ${url("/packages")}`]: answers(status({ missing, install, busy })),
      [`POST ${url("/start")}`]: answers(running)
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.errors).toEqual([])
  })

  it("stops with the server's answer when it stops answering during the install", async () => {
    const busy = "Installing packages"
    const machine = world({
      [`GET ${url()}`]: [...answers(status({ missing, install })), undefined],
      [`POST ${url("/packages")}`]: answers(status({ missing, install, busy }))
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "Codevisor server is not running on port 49361; start it with: codevisor start"
    ])
  })

  it("says the install is still going on when it outlasts the wait, instead of calling it failed", async () => {
    const busy = "Installing packages"
    const machine = world({
      [`GET ${url()}`]: answers(status({ missing, install }), status({ missing, install, busy })),
      [`POST ${url("/packages")}`]: answers(status({ missing, install, busy }))
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "Installing packages is still going on. Run `codevisor desktop setup` again when it is done."
    ])
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(0)
  })

  it("runs sudo in the terminal when the account's sudo asks for a password", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(
        status({ missing, install, sudo: "password" }),
        status({ install, sudo: "password" })
      ),
      [`POST ${url("/start")}`]: answers(running)
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.interactiveCalls).toEqual([
      "sudo env DEBIAN_FRONTEND=noninteractive apt-get update -q",
      "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y xfce4"
    ])
    expect(machine.httpCalls(`POST ${url("/packages")}`)).toBe(0)
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(1)
  })

  it("runs the package manager itself when the command is run by root", async () => {
    const machine = world(
      {
        [`GET ${url()}`]: answers(
          status({ missing, install, sudo: "none" }),
          status({ install, sudo: "none" })
        ),
        [`POST ${url("/start")}`]: answers(running)
      },
      { isRoot: true }
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.interactiveCalls).toEqual([
      "env DEBIAN_FRONTEND=noninteractive apt-get update -q",
      "env DEBIAN_FRONTEND=noninteractive apt-get install -y xfce4"
    ])
  })

  it.each([
    { name: "there is no sudo", sudo: "none" as const, interactive: true },
    { name: "sudo asks and nobody is at a terminal", sudo: "password" as const, interactive: false }
  ])("prints the commands for an administrator and starts nothing when $name", async (given) => {
    const machine = world(
      { [`GET ${url()}`]: answers(status({ missing, install, sudo: given.sudo })) },
      { interactive: given.interactive }
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "Installing packages needs an administrator. Ask one to run:",
      "  env DEBIAN_FRONTEND=noninteractive apt-get update -q",
      "  env DEBIAN_FRONTEND=noninteractive apt-get install -y xfce4",
      "then run `codevisor desktop setup` again."
    ])
    expect(machine.interactiveCalls).toEqual([])
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(0)
  })

  it("names what to install on a system whose package manager it doesn't know", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(status({ missing, system: "Fedora Linux 45" }))
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "Codevisor doesn't know how to install packages on this system.",
      "Install these, then run setup again: Xvnc, startxfce4",
      "(TigerVNC 1.12 or newer for Xvnc, Xfce, xclip, dbus and python3.)"
    ])
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(0)
  })

  it("stops when the package manager fails in the terminal", async () => {
    const fake = makeWorld({
      http: { [`GET ${url()}`]: answers(status({ missing, install, sudo: "password" })) },
      interactiveExit: 100
    })
    const deps: DesktopCliDeps = { ...fake.deps, isInteractive: true, confirm: async () => true }
    expect(await desktopSetupCommand(deps)).toBe(1)
    expect(fake.interactiveCalls).toHaveLength(1)
    expect(fake.errors).toEqual(["Installing packages failed."])
  })

  it("skips the install when everything is already there, and says how to start at boot", async () => {
    const hint = "sudo loginctl enable-linger dev"
    const machine = world({
      [`GET ${url()}`]: answers(status({ sudo: "none" })),
      [`POST ${url("/start")}`]: answers({ ...running, startsAtBoot: false, startAtBootHint: hint })
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.logs.at(-1)).toBe(`    It starts at boot once this account lingers: ${hint}`)
    expect(machine.interactiveCalls).toEqual([])
  })

  it("says a running desktop is already running, and still lets the server make sure", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(running),
      [`POST ${url("/start")}`]: answers(running)
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.logs).toEqual([
      "==> Checking this machine",
      "    Ubuntu 24.04.5 LTS, a desktop is running",
      "==> The desktop is already running. Open it from this machine in Codevisor."
    ])
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(1)
  })

  it("says it is starting a desktop that runs but isn't the server's own, since the server will replace it", async () => {
    const machine = world({
      [`GET ${url()}`]: answers({ ...running, managed: false }),
      [`POST ${url("/start")}`]: answers(running)
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.logs.slice(-2)).toEqual([
      "==> Starting the desktop as codevisor",
      "==> The desktop is ready. Open it from this machine in Codevisor."
    ])
  })

  it("reports the server's reason when the desktop doesn't start", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(status()),
      [`POST ${url("/start")}`]: [
        { status: 500, body: { error: "The desktop didn't start.\nXvnc is missing" } }
      ]
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual(["The desktop didn't start.\nXvnc is missing"])
  })

  it("says to start the server when it isn't running", async () => {
    const machine = world({})
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "Codevisor server is not running on port 49361; start it with: codevisor start"
    ])
  })
})

describe("an older desktop that runs as root", () => {
  const oldDesktop = {
    units: ["vncserver@1.service"],
    removal: [
      ["systemctl", "disable", "--now", "vncserver@1.service"],
      ["systemctl", "daemon-reload"]
    ]
  }
  const question =
    "An older desktop runs as root on this machine. Replace it? Everything open in it will close."

  it("is replaced after asking once, then the new desktop starts", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(status({ oldDesktop })),
      [`POST ${url("/replace-old")}`]: answers(status()),
      [`POST ${url("/start")}`]: answers(running)
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.questions).toEqual([question])
    expect(machine.httpCalls(`POST ${url("/replace-old")}`)).toBe(1)
    expect(machine.logs).toContain("==> Removing the older desktop")
  })

  it("is left alone, with nothing else changed, when the answer is no", async () => {
    const machine = world({ [`GET ${url()}`]: answers(status({ oldDesktop })) }, { agrees: false })
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.httpCalls(`POST ${url("/replace-old")}`)).toBe(0)
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(0)
  })

  it("is not replaced unasked where there is no terminal, unless --yes was given", async () => {
    const http = {
      [`GET ${url()}`]: answers(status({ oldDesktop })),
      [`POST ${url("/replace-old")}`]: answers(status()),
      [`POST ${url("/start")}`]: answers(running)
    }
    const unattended = world(http, { interactive: false })
    expect(await desktopSetupCommand(unattended.deps)).toBe(1)
    expect(unattended.errors).toEqual([
      question,
      "Run this in a terminal to answer, or pass --yes."
    ])
    expect(unattended.httpCalls(`POST ${url("/replace-old")}`)).toBe(0)

    const agreed = world(http, { interactive: false })
    expect(await desktopSetupCommand(agreed.deps, { yes: true })).toBe(0)
    expect(agreed.questions).toEqual([])
    expect(agreed.httpCalls(`POST ${url("/replace-old")}`)).toBe(1)
  })

  it("is removed with sudo in the terminal when the account's sudo asks for a password", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(
        status({ oldDesktop, sudo: "password" }),
        status({ sudo: "password" })
      ),
      [`POST ${url("/start")}`]: answers(running)
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.interactiveCalls).toEqual([
      "sudo systemctl disable --now vncserver@1.service",
      "sudo systemctl daemon-reload"
    ])
  })
})

describe("codevisor desktop status", () => {
  it.each([
    {
      given: status(),
      lines: ["No desktop on this machine. Set one up with: codevisor desktop setup"]
    },
    {
      given: running,
      lines: [
        "The desktop is running as codevisor on display :1.",
        "It starts at boot.",
        "Log: journalctl --user -u codevisor-desktop"
      ]
    },
    {
      given: status({
        state: "stopped",
        display: 2,
        problem: "nothing at /run/user/1001/codevisor-desktop.sock",
        startsAtBoot: false,
        startAtBootHint: "sudo loginctl enable-linger codevisor"
      }),
      lines: [
        "The desktop is set up as codevisor on display :2 but isn't running: nothing at /run/user/1001/codevisor-desktop.sock",
        "It starts at boot once this account lingers: sudo loginctl enable-linger codevisor",
        "Log: journalctl --user -u codevisor-desktop"
      ]
    },
    {
      given: status({
        state: "outdated",
        oldDesktop: { units: ["vncserver@1.service"], removal: [] }
      }),
      lines: [
        "This machine's desktop was set up for an older version of Codevisor.",
        "Set it up again with: codevisor desktop setup",
        "An older desktop still runs as root (vncserver@1.service). Replace it with: codevisor desktop setup"
      ]
    }
  ])("says what is there: $given.state", async ({ given, lines }) => {
    const machine = world({ [`GET ${url()}`]: answers(given) })
    expect(await desktopStatusCommand(machine.deps)).toBe(0)
    expect(machine.logs).toEqual(lines)
  })

  it("says a desktop without a boot service starts with the server", async () => {
    const machine = world({
      [`GET ${url()}`]: answers({ ...running, startsAtBoot: false, logHint: "/logs/desktop.log" })
    })
    await desktopStatusCommand(machine.deps)
    expect(machine.logs).toEqual([
      "The desktop is running as codevisor on display :1.",
      "It starts when the Codevisor server starts, not by itself at boot.",
      "Log: /logs/desktop.log"
    ])
  })

  it("passes on the server's answer on a machine that can't have a desktop", async () => {
    const machine = world({
      [`GET ${url()}`]: [
        { status: 501, body: { error: "A desktop can only be set up on a Linux machine" } }
      ]
    })
    expect(await desktopStatusCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual(["A desktop can only be set up on a Linux machine"])
  })
})

describe("codevisor desktop remove", () => {
  const question = "Remove the desktop? This closes everything open in it."

  it("asks first, then removes it", async () => {
    const machine = world({ [`DELETE ${url()}`]: answers(status()) })
    expect(await desktopRemoveCommand(machine.deps)).toBe(0)
    expect(machine.questions).toEqual([question])
    expect(machine.logs).toEqual(["The desktop is removed. Its packages stay installed."])
  })

  it("removes nothing when the answer is no", async () => {
    const machine = world({ [`DELETE ${url()}`]: answers(status()) }, { agrees: false })
    expect(await desktopRemoveCommand(machine.deps)).toBe(1)
    expect(machine.httpCalls(`DELETE ${url()}`)).toBe(0)
  })

  it("doesn't ask with --yes", async () => {
    const machine = world({ [`DELETE ${url()}`]: answers(status()) }, { interactive: false })
    expect(await desktopRemoveCommand(machine.deps, { yes: true })).toBe(0)
    expect(machine.questions).toEqual([])
  })
})
