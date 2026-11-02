import type { RestartDrainState, UpdateInfo, UpdateRunState } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import type { PauseScope } from "./pause-scope.js"
import type { RestartCoordinator } from "./restart-drain.js"
import { makeUpdateRun, type ServerUpdateSteps } from "./update-run.js"

const release: UpdateInfo = {
  channel: "stable",
  currentVersion: "0.1.0",
  latestVersion: "0.2.0",
  latestBuildNumber: 200,
  migrationState: "idle",
  updateAvailable: true
}

const scopeName = (scope: PauseScope | undefined): string =>
  scope === undefined || scope.kind === "all" ? "all chats" : scope.harnessIds.join("+")

const makeWorld = (options: { readonly server?: ServerUpdateSteps | false } = {}) => {
  const steps: Array<string> = []
  const states: Array<UpdateRunState["state"]> = []
  const paused: Array<string> = []
  const failingPrepare = new Set<string>()
  const installs = new Map<string, PromiseWithResolvers<boolean>>()
  let pauseGate: Promise<void> = Promise.resolve()
  const waiters: Array<{ readonly ready: () => boolean; readonly resolve: () => void }> = []
  const notify = (): void => {
    for (const waiter of waiters.filter((candidate) => candidate.ready())) {
      waiters.splice(waiters.indexOf(waiter), 1)
      waiter.resolve()
    }
  }
  const until = (ready: () => boolean): Promise<void> => {
    if (ready()) return Promise.resolve()
    return new Promise((resolve) => waiters.push({ ready, resolve }))
  }
  let active = false
  let remaining = 0

  const drainState = (): RestartDrainState => ({
    state: active ? "drained" : "idle",
    remaining,
    startedAt: "2026-10-21T00:00:00.000Z",
    pausedSessionIds: paused
  })

  const restart: RestartCoordinator = {
    state: drainState,
    isActive: () => active,
    gates: () => active,
    gateFor: () => ({ harnessId: "codevisor-server", harnessName: "Codevisor" }),
    begin: async (scope) => {
      steps.push(`pause ${scopeName(scope)}`)
      active = true
      await pauseGate
      return drainState()
    },
    cancel: async () => {
      steps.push("continue chats")
      active = false
      updates.noteChatsChanged()
      return drainState()
    },
    extendGrace: () => {
      steps.push("extend grace")
    },
    close: () => {}
  }

  const server: ServerUpdateSteps = {
    check: async () => release,
    apply: async () => {
      steps.push("restart server")
    }
  }

  const updates = makeUpdateRun({
    restart,
    harnesses: {
      prepareUpdate: async (harnessId) => {
        if (failingPrepare.has(harnessId)) throw new Error(`${harnessId} is not installed`)
        steps.push(`prepare ${harnessId}`)
        return { phase: "updating" }
      },
      applyUpdate: (harnessId) => {
        steps.push(`install ${harnessId}`)
        const install = Promise.withResolvers<boolean>()
        installs.set(harnessId, install)
        notify()
        return install.promise
      },
      cancelUpdate: (harnessId) => {
        steps.push(`unprepare ${harnessId}`)
      }
    },
    server: options.server === false ? undefined : (options.server ?? server),
    pausedSessionIds: () => paused,
    onChange: () => {
      if (states.at(-1) !== updates.state().state) states.push(updates.state().state)
      notify()
    },
    log: (line) => steps.push(`log: ${line}`)
  })

  const settled = (state: UpdateRunState["state"]): Promise<void> =>
    until(() => updates.state().state === state)

  const installed = async (harnessId: string): Promise<void> => {
    await until(() => installs.has(harnessId))
    installs.get(harnessId)?.resolve(true)
  }

  const brokeInstalling = async (harnessId: string, cause: Error): Promise<void> => {
    await until(() => installs.has(harnessId))
    installs.get(harnessId)?.reject(cause)
  }

  return {
    updates,
    restart,
    steps,
    states,
    paused,
    failingPrepare,
    installs,
    installed,
    brokeInstalling,
    settled,
    holdPause: () => {
      const gate = Promise.withResolvers<void>()
      pauseGate = gate.promise
      return gate
    },
    setRemaining: (count: number) => {
      remaining = count
    }
  }
}

describe("update run", () => {
  it("continues the chats once, after every harness has installed", async () => {
    const world = makeWorld()
    world.paused.push("chat-a")

    await world.updates.start({ harnessIds: ["claude-code", "codex", "codex"] })
    await world.installed("claude-code")
    await world.installed("codex")
    await world.settled("continuing")

    expect(world.steps).toEqual([
      "prepare claude-code",
      "prepare codex",
      "pause claude-code+codex",
      "pause claude-code+codex",
      "extend grace",
      "install claude-code",
      "pause claude-code+codex",
      "extend grace",
      "install codex",
      "continue chats"
    ])
    world.paused.length = 0
    world.updates.noteChatsChanged()
    expect(world.states).toEqual(["pausing", "updating", "continuing", "idle"])
  })

  it("pauses only the updating harness's chats, then every chat just before the restart", async () => {
    const world = makeWorld()

    const started = await world.updates.start({
      harnessIds: ["codex"],
      serverChannel: "stable"
    })
    await world.settled("updating")
    expect(world.updates.restartsServer()).toBe(true)
    await world.installed("codex")
    await world.settled("restarting")

    expect(started.server).toEqual({
      accepted: true,
      targetVersion: "0.2.0",
      targetBuildNumber: 200,
      draining: false
    })
    expect(world.steps).toEqual([
      "prepare codex",
      "pause codex",
      "pause codex",
      "extend grace",
      "install codex",
      "pause all chats",
      "restart server"
    ])
    expect(world.states).toEqual(["pausing", "updating", "pausing", "restarting"])
  })

  it("keeps chats paused for the app update, and continues them if the app never restarts", async () => {
    const world = makeWorld()

    await world.updates.start({ harnessIds: ["codex"], holdForAppUpdate: true })
    await world.installed("codex")
    await world.settled("holding")

    expect(world.steps.at(-1)).toBe("extend grace")
    expect(world.steps).not.toContain("continue chats")
    await world.restart.cancel()
    expect(world.updates.state().state).toBe("idle")
  })

  it("carries on past a harness whose install breaks, through the server restart", async () => {
    const world = makeWorld()

    await world.updates.start({ harnessIds: ["codex", "gemini"], serverChannel: "stable" })
    await world.brokeInstalling("codex", new Error("terminal unavailable"))
    await world.installed("gemini")
    await world.settled("restarting")

    expect(world.steps.slice(-6)).toEqual([
      "log: The codex update failed: terminal unavailable",
      "pause codex+gemini",
      "extend grace",
      "install gemini",
      "pause all chats",
      "restart server"
    ])
    expect(world.steps).not.toContain("continue chats")
  })

  it("keeps a harness-only run going when one install breaks, then continues the chats", async () => {
    const world = makeWorld()

    await world.updates.start({ harnessIds: ["codex", "gemini"] })
    await world.brokeInstalling("codex", new Error("terminal unavailable"))
    await world.installed("gemini")
    await world.settled("idle")

    expect(world.steps).toContain("log: The codex update failed: terminal unavailable")
    expect(world.steps.slice(-2)).toEqual(["install gemini", "continue chats"])
    expect(world.updates.restartsServer()).toBe(false)
  })

  it("changes nothing when the server is already current", async () => {
    const world = makeWorld({ server: { ...makeServerSteps(), check: async () => current } })

    await expect(world.updates.startServerUpdate("alpha")).resolves.toEqual({
      accepted: false,
      targetVersion: "0.1.0"
    })
    expect(world.steps).toEqual([])
    expect(world.updates.state().state).toBe("idle")
  })

  it("lets a retried server update replace one still waiting for its restart", async () => {
    const world = makeWorld()
    await world.updates.start({ harnessIds: ["codex"], serverChannel: "stable" })
    await world.settled("updating")

    await expect(world.updates.startServerUpdate("stable")).resolves.toMatchObject({
      accepted: true
    })
    await world.installed("codex")
    await world.settled("restarting")
    await expect(world.updates.startServerUpdate("stable")).resolves.toMatchObject({
      accepted: true
    })
    expect(world.steps.filter((step) => step === "restart server")).toHaveLength(2)
  })

  it("adds harnesses to a running pause until its installs finish", async () => {
    const world = makeWorld()
    world.paused.push("chat-a")
    await world.updates.start({ harnessIds: ["claude-code"] })
    await world.settled("updating")

    await world.updates.start({ harnessIds: ["codex", "claude-code"] })
    await world.installed("claude-code")
    await world.installed("codex")
    await world.settled("continuing")

    expect(world.updates.state().harnessIds).toEqual(["claude-code", "codex"])
    expect(world.steps.filter((step) => step === "continue chats")).toHaveLength(1)
    expect(world.steps).toContain("pause claude-code+codex")
  })

  it("widens an app-update hold to every chat only after the joined harnesses install", async () => {
    const world = makeWorld()
    await world.updates.start({ harnessIds: ["claude-code"], holdForAppUpdate: true })
    await world.settled("updating")

    await world.updates.start({ harnessIds: ["codex"] })
    await world.installed("claude-code")
    await world.installed("codex")
    await world.settled("holding")

    expect(world.steps.filter((step) => step.startsWith("pause"))).toEqual([
      "pause claude-code",
      "pause claude-code",
      "pause claude-code+codex",
      "pause claude-code+codex",
      "pause all chats"
    ])
  })

  it("lets a server update join a running harness run and restart once its installs finish", async () => {
    const world = makeWorld()
    await world.updates.start({ harnessIds: ["claude-code"] })
    await world.settled("updating")

    const joined = await world.updates.start({ harnessIds: ["codex"], serverChannel: "stable" })
    await world.installed("claude-code")
    await world.installed("codex")
    await world.settled("restarting")

    expect(joined.server).toMatchObject({ accepted: true, targetVersion: "0.2.0" })
    expect(world.steps.slice(-2)).toEqual(["pause all chats", "restart server"])
    expect(world.steps).not.toContain("continue chats")
  })

  it("refuses to join a run whose harness installs are done", async () => {
    const world = makeWorld()
    await world.updates.start({ harnessIds: ["codex"], holdForAppUpdate: true })
    await world.installed("codex")
    await world.settled("holding")

    await expect(world.updates.start({ harnessIds: ["gemini"] })).rejects.toMatchObject({
      status: 409
    })
  })

  it("skips a harness that can't start updating and updates the rest", async () => {
    const world = makeWorld()
    world.failingPrepare.add("gemini")

    const started = await world.updates.start({ harnessIds: ["codex", "gemini"] })
    await world.installed("codex")
    await world.settled("idle")

    expect(started.run.harnessIds).toEqual(["codex"])
    expect(world.steps.slice(0, 3)).toEqual([
      "prepare codex",
      "log: Skipping the gemini update: gemini is not installed",
      "pause codex"
    ])
    await expect(world.updates.start({ harnessIds: ["gemini"] })).rejects.toMatchObject({
      status: 409,
      message: "gemini is not installed"
    })
  })

  it("never lets a harness that can't start updating stop the server update", async () => {
    const world = makeWorld()
    world.failingPrepare.add("claude-code")

    const started = await world.updates.start({
      harnessIds: ["claude-code"],
      serverChannel: "stable"
    })
    await world.settled("restarting")

    expect(started.server).toMatchObject({ accepted: true })
    expect(world.steps).toEqual([
      "log: Skipping the claude-code update: claude-code is not installed",
      "pause all chats",
      "restart server"
    ])
  })

  it("can only be cancelled while chats are pausing, and then installs nothing", async () => {
    const world = makeWorld()
    await expect(world.updates.cancel()).rejects.toMatchObject({ status: 409 })
    const pausing = world.holdPause()
    world.setRemaining(2)

    await world.updates.start({ harnessIds: ["codex"] })
    expect(world.updates.state()).toMatchObject({ state: "pausing", pausing: 2 })
    world.updates.noteChatsChanged()
    await world.updates.cancel()
    pausing.resolve()
    await world.settled("idle")

    expect(world.steps).toEqual([
      "prepare codex",
      "pause codex",
      "continue chats",
      "unprepare codex"
    ])
    expect(world.installs.size).toBe(0)
  })
})

const current: UpdateInfo = { ...release, latestVersion: "0.1.0", updateAvailable: false }

const makeServerSteps = (): ServerUpdateSteps => ({
  check: async () => release,
  apply: async () => {}
})
