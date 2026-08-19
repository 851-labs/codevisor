import { describe, expect, it } from "vitest"
import { makePluginSupervisor } from "./plugin-supervisor.js"
import { delay, fakeSpawn, makeDataDir, plugin } from "./test-support.js"

/// Idle shutdown, WS pinning, crash backoff, and the circuit breaker — the
/// Phase 3 supervision-hardening behaviors, unit tested with short real
/// timeouts and an injectable clock.

describe("idle shutdown", () => {
  it("stops an idle plugin and relaunches on the next request", async () => {
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      spawnShell: spawn.spawnShell
    })
    const target = plugin({ idleTimeoutSeconds: 0.12 })
    await supervisor.ensureRunning(target)
    expect(supervisor.state("owner.example")).toBe("running")
    await expect.poll(() => supervisor.state("owner.example")).toBe("stopped")
    expect(spawn.spawnCount()).toBe(1)
    await supervisor.ensureRunning(target)
    expect(supervisor.state("owner.example")).toBe("running")
    expect(spawn.spawnCount()).toBe(2)
    supervisor.closeAll()
  })

  it("never idles out plugins with idleTimeoutSeconds 0", async () => {
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      spawnShell: spawn.spawnShell
    })
    await supervisor.ensureRunning(plugin({ idleTimeoutSeconds: 0 }))
    await delay(250)
    expect(supervisor.state("owner.example")).toBe("running")
    supervisor.closeAll()
  })

  it("keeps an active plugin alive, then idles out once requests stop", async () => {
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      spawnShell: spawn.spawnShell
    })
    const target = plugin({ idleTimeoutSeconds: 0.25 })
    await supervisor.ensureRunning(target)
    for (let index = 0; index < 4; index += 1) {
      await delay(100)
      // Each proxied request resets the idle clock through ensureRunning.
      await supervisor.ensureRunning(target)
    }
    expect(supervisor.state("owner.example")).toBe("running")
    expect(spawn.spawnCount()).toBe(1)
    await expect.poll(() => supervisor.state("owner.example")).toBe("stopped")
  })

  it("pins the process alive while a splice is open", async () => {
    const spawn = fakeSpawn()
    const supervisor = makePluginSupervisor({
      dataDir: makeDataDir(),
      spawnShell: spawn.spawnShell
    })
    await supervisor.ensureRunning(plugin({ idleTimeoutSeconds: 0.12 }))
    const release = supervisor.pin("owner.example")
    await delay(350)
    expect(supervisor.state("owner.example")).toBe("running")
    release()
    // Releases are idempotent: a double close must not unbalance the count.
    release()
    await expect.poll(() => supervisor.state("owner.example")).toBe("stopped")
    expect(spawn.spawnCount()).toBe(1)
  })
})

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
      onStateChange: (_pluginId, state) => transitions.push(state),
      readyTimeoutMs: 300,
      spawnShell: spawn.spawnShell
    })
    await expect(supervisor.ensureRunning(plugin())).rejects.toThrow(/did not start listening/)
    expect(transitions).toEqual(["starting", "failed"])
  })
})
