import { createServer } from "node:http"

import { describe, expect, it, onTestFinished } from "vitest"

import {
  answers,
  removeTheOldOne,
  running,
  status,
  url,
  withAnOldRootDesktop,
  world
} from "./desktop-test-support.js"
import { desktopRemoveCommand, desktopSetupCommand, desktopStatusCommand } from "./desktop.js"
import { fetchJson } from "./fetch-json.js"

describe("codevisor desktop remove", () => {
  const question = "Remove the desktop? This closes everything open in it."
  const http = { [`GET ${url()}`]: answers(running), [`DELETE ${url()}`]: answers(status()) }

  it("asks first, then removes it", async () => {
    const machine = world(http)
    expect(await desktopRemoveCommand(machine.deps)).toBe(0)
    expect(machine.questions).toEqual([question])
    expect(machine.logs).toEqual(["The desktop is removed. Its packages stay installed."])
  })

  it("removes nothing when the answer is no", async () => {
    const machine = world(http, { agrees: false })
    expect(await desktopRemoveCommand(machine.deps)).toBe(1)
    expect(machine.httpCalls(`DELETE ${url()}`)).toBe(0)
  })

  it("doesn't ask with --yes", async () => {
    const machine = world(http, { interactive: false })
    expect(await desktopRemoveCommand(machine.deps, { yes: true })).toBe(0)
    expect(machine.questions).toEqual([])
  })

  it("only stops sharing a desktop Codevisor didn't set up, asks about that, and says it still runs", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(status({ state: "running", unmanaged: true })),
      [`DELETE ${url("?unshare=1")}`]: answers(status())
    })
    expect(await desktopRemoveCommand(machine.deps)).toBe(0)
    expect(machine.questions).toEqual([
      "The desktop shared from this machine wasn't set up by Codevisor. Stop sharing it? It keeps running; Codevisor only forgets it."
    ])
    expect(machine.logs).toEqual([
      "The desktop is no longer shared. It wasn't Codevisor's, so it was left running."
    ])
    expect(machine.httpCalls(`DELETE ${url()}`)).toBe(0)
  })
})

describe("an older root desktop that survives its removal", () => {
  const xServer = "root 880 /usr/bin/Xtigervnc :1 -localhost=1 -rfbport 5901\n"
  const stillThere = {
    ...withAnOldRootDesktop,
    results: { "ps -eo user=,pid=,args=": { code: 0, output: xServer } }
  }

  it("stops setup with what is still running, instead of saying it was replaced", async () => {
    const machine = world(
      {
        [`GET ${url()}`]: answers(status({ sudo: "password" })),
        [`POST ${url("/start")}`]: answers(running)
      },
      { machine: stillThere }
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.interactiveCalls).toEqual(removeTheOldOne.map((command) => `sudo ${command}`))
    expect(machine.errors).toEqual([
      "The older desktop is still running: a root X server on :1 (pid 880).",
      "Stop it, then run `codevisor desktop setup` again."
    ])
    expect(machine.httpCalls(`POST ${url("/start")}`)).toBe(0)
  })

  it("is stopped too when it was started by hand and never enabled", async () => {
    const listUnits = "systemctl list-units --all --plain --no-legend vncserver@*.service"
    const startedByHand = {
      ...withAnOldRootDesktop,
      folders: {},
      results: {
        [listUnits]: { code: 0, output: "vncserver@2.service loaded active running Codevisor\n" }
      }
    }
    const machine = world(
      {
        [`GET ${url()}`]: answers(status({ sudo: "password" })),
        [`POST ${url("/start")}`]: answers(running)
      },
      { machine: startedByHand }
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.interactiveCalls[0]).toBe("sudo systemctl disable --now vncserver@2.service")
  })
})

describe("answers the command can't use", () => {
  it("says so in one plain line when the answer isn't a desktop status", async () => {
    const machine = world({ [`GET ${url()}`]: [{ status: 200, body: { state: "sideways" } }] })
    expect(await desktopStatusCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      "The server's answer about the desktop wasn't understood. The server may be older or newer than this command."
    ])
  })

  it("tells a server that didn't answer in time from one that isn't running", async () => {
    const silent = createServer(() => undefined)
    await new Promise<void>((resolve) => silent.listen(0, "127.0.0.1", resolve))
    onTestFinished(() => {
      silent.closeAllConnections()
      silent.close()
    })
    const address = silent.address()
    const port = typeof address === "object" && address !== null ? address.port : 0

    expect(await fetchJson(`http://127.0.0.1:${port}/v1/desktop`, { timeoutMs: 50 })).toEqual({
      status: 408,
      body: {
        error: `The Codevisor server on port ${port} is running but didn't answer within 0 s`
      }
    })
    silent.closeAllConnections()
    await new Promise<void>((resolve) => silent.close(() => resolve()))
    expect(await fetchJson(`http://127.0.0.1:${port}/v1/desktop`, { timeoutMs: 2000 })).toBe(
      undefined
    )
  })
})
