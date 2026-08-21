import { rmSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import type { PluginStateEvent } from "./plugins-manager.js"
import { fakeSpawn, makeManager, makeOuterServer } from "./test-support.js"

/// Manager-level supervision behaviors: explicit restart, state-change
/// fanout, and always-running process ownership.

describe("restart", () => {
  it("stops the running process, clears crash state, and returns the summary", async () => {
    const { manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", { paneType: "main" })
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    expect((await manager.get("owner.example")).state).toBe("running")
    const summary = await manager.restart("owner.example")
    expect(summary.id).toBe("owner.example")
    expect(summary.state).toBe("running")
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    expect((await manager.get("owner.example")).state).toBe("running")
  })

  it("rejects restarting plugins that are not installed", async () => {
    const { manager } = makeManager()
    await expect(manager.restart("owner.ghost")).rejects.toThrow(/not installed/)
  })
})

describe("state events", () => {
  it("emits a summary on every transition and stops after unsubscribe", async () => {
    const { manager } = makeManager()
    const events: Array<PluginStateEvent> = []
    const unsubscribe = manager.subscribe((event) => events.push(event))
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", { paneType: "main" })
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    expect(events.map((event) => event.payload.state)).toEqual(["starting", "running"])
    expect(events[0]?.kind).toBe("plugin.state.updated")
    expect(events[0]?.subjectId).toBe("owner.example")
    expect(events[0]?.payload.id).toBe("owner.example")
    await manager.restart("owner.example")
    expect(events.map((event) => event.payload.state)).toEqual([
      "starting",
      "running",
      "stopping",
      "stopped",
      "starting",
      "running"
    ])
    unsubscribe()
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    expect(events).toHaveLength(6)
  })

  it("skips events for plugins removed from disk mid-flight", async () => {
    const { manager, root } = makeManager()
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", { paneType: "main" })
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    const events: Array<PluginStateEvent> = []
    manager.subscribe((event) => events.push(event))
    rmSync(join(root, "example"), { force: true, recursive: true })
    // Shutdown still transitions the runtime, but there is no plugin left to
    // summarize — the event is dropped instead of throwing.
    manager.close()
    expect(events).toHaveLength(0)
  })
})

describe("always-running lifecycle", () => {
  it("starts installed plugins and restarts them after a crash", async () => {
    const { fake, manager } = makeManager({ backoffBaseMs: 0 })
    await Promise.all([manager.startAll(), manager.startAll()])
    expect((await manager.get("owner.example")).state).toBe("running")
    expect(fake.spawnCount()).toBe(1)
    fake.simulateExit("exited with code 1")
    await expect.poll(() => fake.spawnCount()).toBe(2)
    expect((await manager.get("owner.example")).state).toBe("running")
    manager.close()
    await manager.startAll()
  })

  it("stops automatic retries after the circuit breaker trips", async () => {
    const spawn = fakeSpawn({ listen: false })
    const { manager } = makeManager({
      maxConsecutiveFailures: 1,
      readyTimeoutMs: 200,
      spawnShell: spawn.spawnShell
    })
    await manager.startAll()
    expect((await manager.get("owner.example")).state).toBe("failed")
  })
})
