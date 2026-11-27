import type { DesktopStatus, ScreenStatus } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import type { DesktopManager } from "../desktop/desktop-manager.js"
import type { ScreenShare } from "../desktop/screen-share.js"
import { HttpFailure } from "../server-context.js"
import { jsonRequest, makeServices, readWebSocketEvents, startWithApp } from "../test-support.js"
import { field } from "../unknown-values.js"

const status = (state: DesktopStatus["state"]): DesktopStatus => ({
  state,
  account: "codevisor",
  system: "Ubuntu 24.04.5 LTS",
  missing: [],
  sudo: "passwordless",
  startsAtBoot: true,
  logHint: "journalctl --user -u codevisor-desktop"
})

const recordingManager = (overrides: Partial<DesktopManager> = {}) => {
  const calls: string[] = []
  const answer = (name: string, state: DesktopStatus["state"]) => async () => {
    calls.push(name)
    return status(state)
  }
  const manager: DesktopManager = {
    status: answer("status", "none"),
    installPackages: answer("installPackages", "none"),
    replaceOld: answer("replaceOld", "none"),
    start: answer("start", "running"),
    remove: answer("remove", "none"),
    resume: async () => undefined,
    ...overrides
  }
  return { manager, calls }
}

const recordingScreen = () => {
  const calls: string[] = []
  const answer = (name: string, state: ScreenStatus["state"]) => async () => {
    calls.push(name)
    return { state, missing: [], others: [] }
  }
  const screen: ScreenShare = {
    status: answer("status", "waiting"),
    installPackages: answer("installPackages", "none"),
    setUp: answer("setUp", "waiting"),
    remove: answer("remove", "none"),
    follow: async () => undefined,
    viewerJoined: () => undefined
  }
  return { screen, calls }
}

const start = async (manager: DesktopManager | undefined, screen?: ScreenShare) => {
  const { services } = await makeServices()
  const server = await startWithApp(services, undefined, { desktop: manager, screen })
  const call = (method: string, path = "", headers: Record<string, string> = {}) =>
    jsonRequest(server, `/v1/desktop${path}`, { method, headers })
  return { server, call }
}

describe("the desktop routes", () => {
  it("map each request to one thing the desktop manager does", async () => {
    const { manager, calls } = recordingManager()
    const { call } = await start(manager)
    expect(await call("GET")).toEqual({ status: 200, body: status("none") })
    expect((await call("POST", "/packages")).status).toBe(200)
    expect((await call("POST", "/replace-old")).status).toBe(200)
    expect((await call("POST", "/start")).body).toMatchObject({ state: "running" })
    expect((await call("DELETE")).body).toMatchObject({ state: "none" })
    expect(calls).toEqual(["status", "installPackages", "replaceOld", "start", "remove"])
  })

  it("map the screen's requests to the screen share, and answer with both statuses", async () => {
    const { manager } = recordingManager()
    const { screen, calls } = recordingScreen()
    const { call } = await start(manager, screen)
    const withTheScreen = { state: "none", screen: { state: "waiting", missing: [], others: [] } }

    expect((await call("GET")).body).toMatchObject(withTheScreen)
    expect((await call("POST", "/screen/packages")).body).toMatchObject(withTheScreen)
    expect((await call("POST", "/screen")).body).toMatchObject(withTheScreen)
    expect((await call("DELETE", "/screen")).body).toMatchObject(withTheScreen)
    expect(calls.filter((name) => name !== "status")).toEqual([
      "installPackages",
      "setUp",
      "remove"
    ])
  })

  it("say so when this server can't share a screen", async () => {
    const { call } = await start(recordingManager().manager)

    expect(await call("POST", "/screen")).toMatchObject({
      status: 501,
      body: { error: "This server can't share the machine's screen" }
    })
  })

  it("pass on that replacing a desktop Codevisor didn't set up was asked for, and only then", async () => {
    const asked: unknown[] = []
    const { manager } = recordingManager({
      start: async (options) => {
        asked.push(options)
        return status("running")
      }
    })
    const { call } = await start(manager)
    await call("POST", "/start")
    await call("POST", "/start?replace=1")
    expect(asked).toEqual([{ replaceUnmanaged: false }, { replaceUnmanaged: true }])
  })

  it("answer with the manager's reason when it refuses", async () => {
    const { manager } = recordingManager({
      installPackages: async () => {
        throw new HttpFailure(403, "Installing packages needs an administrator on this machine")
      }
    })
    const { call } = await start(manager)
    expect(await call("POST", "/packages")).toEqual({
      status: 403,
      body: { error: "Installing packages needs an administrator on this machine" }
    })
  })

  it("refuse browsers, and say so on a machine that can't have a desktop", async () => {
    const { manager, calls } = recordingManager()
    const linux = await start(manager)
    expect((await linux.call("POST", "/start", { Origin: "https://evil.example" })).status).toBe(
      403
    )
    expect(calls).toEqual([])

    const mac = await start(undefined)
    expect(await mac.call("GET")).toEqual({
      status: 501,
      body: { error: "A desktop can only be set up on a Linux machine" }
    })
  })

  it("tell connected apps the machine's features changed after a start or a removal, even a failed start", async () => {
    const { manager } = recordingManager({
      start: async () => {
        throw new HttpFailure(500, "The desktop didn't start.")
      }
    })
    const { server, call } = await start(manager)
    await call("GET")
    await call("POST", "/packages")
    expect((await call("POST", "/start")).status).toBe(500)
    await call("DELETE")

    const events = await readWebSocketEvents(server, 2, 0)
    expect(events.map((event) => field(event, "kind"))).toEqual([
      "server.features.updated",
      "server.features.updated"
    ])
  })
})
