import { describe, expect, it } from "vitest"

import { makePluginSupervisor } from "./plugin-supervisor.js"
import { fakeSpawn, makeDataDir, plugin } from "./test-support.js"

describe("plugin process ownership", () => {
  it("stop invalidates startup before port allocation returns", async () => {
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      spawnShell: spawn.spawnShell
    })
    const target = plugin()
    const start = supervisor.ensureRunning(target)
    supervisor.stop(target.id)
    await expect(start).rejects.toThrow("startup was stopped")
    expect(spawn.spawnCount()).toBe(0)
    expect(supervisor.state(target.id)).toBe("stopped")
  })
  it.each(["stop", "restart", "closeAll"] as const)(
    "%s invalidates a suspended start without touching its replacement",
    async (action) => {
      const entered = Promise.withResolvers<void>()
      const release = Promise.withResolvers<void>()
      const spawn = fakeSpawn()
      let resolutions = 0
      const supervisor = makePluginSupervisor({
        dataDir: makeDataDir(),
        spawnShell: spawn.spawnShell,
        resolveEnv: async () => {
          if (++resolutions === 1) {
            entered.resolve()
            await release.promise
          }
          return {}
        }
      })
      const target = plugin()
      const old = supervisor.ensureRunning(target)
      const rejected = expect(old).rejects.toThrow("startup was stopped")
      try {
        await entered.promise
        if (action === "closeAll") supervisor.closeAll()
        else supervisor[action](target.id)
        await supervisor.ensureRunning(target)
        release.resolve()
        await rejected
        expect(spawn.spawnCount()).toBe(1)
        expect(supervisor.state(target.id)).toBe("running")
      } finally {
        release.resolve()
        await old.catch(() => undefined)
        supervisor.closeAll()
      }
    }
  )

  it("late request outcomes apply only to the process that served them", async () => {
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      spawnShell: spawn.spawnShell,
      maxConsecutiveFailures: 1
    })
    const target = plugin()
    try {
      const old = await supervisor.acquire(target)
      supervisor.restart(target.id)
      const current = await supervisor.acquire(target)
      supervisor.markUnreachable(target.id, old)
      expect(supervisor.state(target.id)).toBe("running")
      expect(await supervisor.acquire(target)).toBe(current)
      spawn.simulateExit("exited")
      supervisor.noteSuccess(target.id, old)
      await expect(supervisor.ensureRunning(target)).rejects.toThrow("failed 1 times")
    } finally {
      supervisor.closeAll()
    }
  })

  it("a synchronous exit during an unreachable kill counts as one crash", async () => {
    const spawn = fakeSpawn()
    const exits: string[] = []
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      maxConsecutiveFailures: 2,
      now: () => 0,
      onUnexpectedExit: (id) => exits.push(id),
      spawnShell: (command, options) => {
        const child = spawn.spawnShell(command, options)
        return {
          ...child,
          kill: () => {
            spawn.simulateExit("killed")
            child.kill()
          }
        }
      }
    })
    const target = plugin()
    try {
      supervisor.markUnreachable(target.id, await supervisor.acquire(target))
      expect(exits).toEqual([target.id])
      expect(supervisor.state(target.id)).toBe("stopped")
    } finally {
      supervisor.closeAll()
    }
  })
})
