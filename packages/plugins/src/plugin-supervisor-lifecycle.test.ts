import { describe, expect, it } from "vitest"
import { makePluginSupervisor } from "./plugin-supervisor.js"
import { fakeSpawn, makeDataDir, plugin } from "./test-support.js"

/// Crash backoff and the circuit breaker, unit tested with an injectable
/// clock. Process lifetime is owned by the manager's always-running loop.

describe("crash backoff and circuit breaker", () => {
  it("refuses restarts inside the crash-backoff window, then relaunches", async () => {
    let skew = 0
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      now: () => Date.now() + skew,
      spawnShell: spawn.spawnShell
    })
    const target = plugin()
    await supervisor.ensureRunning(target)
    spawn.simulateExit("exited with code 1")
    expect(supervisor.state("owner.example")).toBe("stopped")
    await expect(supervisor.ensureRunning(target)).rejects.toThrow(/recently crashed; retry in/)
    skew += 1_000
    await supervisor.ensureRunning(target)
    expect(supervisor.state("owner.example")).toBe("running")
    expect(spawn.spawnCount()).toBe(2)
    supervisor.closeAll()
  })

  it("trips the circuit breaker after consecutive crashes until restarted", async () => {
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      backoffBaseMs: 0,
      dataDir: makeDataDir(),
      maxConsecutiveFailures: 2,
      spawnShell: spawn.spawnShell
    })
    const target = plugin()
    await supervisor.ensureRunning(target)
    spawn.simulateExit("exited with code 1")
    expect(supervisor.state("owner.example")).toBe("stopped")
    await supervisor.ensureRunning(target)
    spawn.simulateExit("exited with code 1")
    expect(supervisor.state("owner.example")).toBe("failed")
    await expect(supervisor.ensureRunning(target)).rejects.toThrow(/failed 2 times in a row/)
    expect(supervisor.state("owner.example")).toBe("failed")
    // Explicit restart clears the breaker; the next request starts fresh.
    supervisor.restart("owner.example")
    expect(supervisor.state("owner.example")).toBe("stopped")
    await supervisor.ensureRunning(target)
    expect(supervisor.state("owner.example")).toBe("running")
    supervisor.closeAll()
  })

  it("clears the crash accounting after a successful request", async () => {
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      backoffBaseMs: 0,
      dataDir: makeDataDir(),
      maxConsecutiveFailures: 2,
      spawnShell: spawn.spawnShell
    })
    const target = plugin()
    await supervisor.ensureRunning(target)
    spawn.simulateExit("exited with code 1")
    await supervisor.ensureRunning(target)
    supervisor.noteSuccess("owner.example")
    spawn.simulateExit("exited with code 1")
    // Without the reset this second crash would have tripped the breaker.
    expect(supervisor.state("owner.example")).toBe("stopped")
    await supervisor.ensureRunning(target)
    expect(supervisor.state("owner.example")).toBe("running")
    supervisor.closeAll()
  })

  it("does not treat occasional failures after a stable runtime as a crash loop", async () => {
    let now = 0
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      backoffBaseMs: 0,
      dataDir: makeDataDir(),
      maxConsecutiveFailures: 2,
      now: () => now,
      spawnShell: spawn.spawnShell,
      stableRuntimeMs: 100
    })
    const target = plugin()
    await supervisor.ensureRunning(target)
    spawn.simulateExit("exited with code 1")
    await supervisor.ensureRunning(target)
    now = 100
    spawn.simulateExit("exited with code 1")
    // The stable second run resets the earlier failure before this crash is
    // counted, so the process remains eligible for automatic recovery.
    expect(supervisor.state("owner.example")).toBe("stopped")
    await supervisor.ensureRunning(target)
    expect(supervisor.state("owner.example")).toBe("running")
    supervisor.closeAll()
  })

  it("treats markUnreachable as a crash of the live process only", async () => {
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      backoffBaseMs: 0,
      dataDir: makeDataDir(),
      spawnShell: spawn.spawnShell
    })
    const target = plugin()
    await supervisor.ensureRunning(target)
    supervisor.markUnreachable("owner.example")
    expect(supervisor.state("owner.example")).toBe("stopped")
    await supervisor.ensureRunning(target)
    expect(spawn.spawnCount()).toBe(2)
    supervisor.stop("owner.example")
    // Not running (and unknown) plugins are no-ops.
    supervisor.markUnreachable("owner.example")
    supervisor.markUnreachable("owner.unknown")
    expect(supervisor.state("owner.example")).toBe("stopped")
  })

  it("noteSuccess ignores plugins that never ran", () => {
    const supervisor = makePluginSupervisor({ dataDir: makeDataDir() })
    supervisor.noteSuccess("owner.unknown")
    expect(supervisor.state("owner.unknown")).toBe("stopped")
  })
})

describe("state change notifications", () => {
  it("reports every state transition and stays quiet on redundant stops", async () => {
    const spawn = fakeSpawn()
    const transitions: Array<string> = []
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      onStateChange: (pluginId, state) => transitions.push(`${pluginId}:${state}`),
      spawnShell: spawn.spawnShell
    })
    await supervisor.ensureRunning(plugin())
    expect(transitions).toEqual(["owner.example:starting", "owner.example:running"])
    supervisor.stop("owner.example")
    expect(transitions).toEqual([
      "owner.example:starting",
      "owner.example:running",
      "owner.example:stopping",
      "owner.example:stopped"
    ])
    supervisor.stop("owner.example")
    expect(transitions).toHaveLength(4)
  })

  it("reports failed starts through the state seam", async () => {
    const spawn = fakeSpawn({ listen: false })
    const transitions: Array<string> = []
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      maxConsecutiveFailures: 1,
      onStateChange: (_pluginId, state) => transitions.push(state),
      readyTimeoutMs: 300,
      spawnShell: spawn.spawnShell
    })
    await expect(supervisor.ensureRunning(plugin())).rejects.toThrow(/did not start listening/)
    expect(transitions).toEqual(["starting", "failed"])
  })
})
