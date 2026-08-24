import { renameSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import type { PluginStateEvent } from "./plugins-manager.js"
import { MANAGED_PLUGIN_MARKER, MANAGED_PLUGIN_MARKER_CONTENT } from "./plugin-store.js"
import {
  exampleManifest,
  fakeSpawn,
  makeDir,
  makeManager,
  makeOuterServer,
  toolManifest,
  writePlugin
} from "./test-support.js"

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

describe("enabled state and recovery", () => {
  it("persists disablement, blocks runtime access, and re-enables cleanly", async () => {
    const dataDir = makeDir("codevisor-plugin-enabled-manager-")
    const first = makeManager({ dataDir }, toolManifest)
    await first.manager.startAll()
    expect(first.fake.spawnCount()).toBe(1)
    expect((await first.manager.setEnabled("owner.notes", false)).enabled).toBe(false)
    expect((await first.manager.get("owner.notes")).state).toBe("stopped")
    expect(await first.manager.listTools()).toEqual([])
    await expect(
      first.manager.issuePaneToken("owner.notes", "pane-1", { paneType: "main" })
    ).rejects.toThrow("disabled")
    await expect(first.manager.restart("owner.notes")).rejects.toThrow("disabled")
    first.manager.close()

    const second = makeManager({ dataDir }, toolManifest)
    expect((await second.manager.get("owner.notes")).enabled).toBe(false)
    await second.manager.startAll()
    expect(second.fake.spawnCount()).toBe(0)
    const enabled = await second.manager.setEnabled("owner.notes", true)
    expect(enabled.enabled).toBe(true)
    expect(enabled.state).toBe("running")
    expect(second.fake.spawnCount()).toBe(1)
    expect(await second.manager.listTools()).toHaveLength(toolManifest.tools.length)
  })

  it("restores and toggles the retained known-good managed version", async () => {
    const { manager, root } = makeManager()
    renameSync(join(root, "example"), join(root, "owner.example"))
    writeFileSync(join(root, "owner.example", MANAGED_PLUGIN_MARKER), MANAGED_PLUGIN_MARKER_CONTENT)
    writePlugin(root, ".owner.example.known-good", { ...exampleManifest, version: "0.0.9" })
    writeFileSync(
      join(root, ".owner.example.known-good", MANAGED_PLUGIN_MARKER),
      MANAGED_PLUGIN_MARKER_CONTENT
    )

    expect((await manager.get("owner.example")).canRestore).toBe(true)
    await manager.setEnabled("owner.example", false)
    await expect(manager.restore("owner.example")).resolves.toMatchObject({
      version: "0.0.9",
      enabled: false,
      state: "stopped"
    })
    expect((await manager.restore("owner.example")).version).toBe("0.1.0")
  })

  it("keeps enablement persisted when startup fails", async () => {
    const spawn = fakeSpawn({ listen: false })
    const { manager } = makeManager({
      maxConsecutiveFailures: 1,
      readyTimeoutMs: 100,
      spawnShell: spawn.spawnShell
    })
    await manager.setEnabled("owner.example", false)
    const enabled = await manager.setEnabled("owner.example", true)
    expect(enabled.enabled).toBe(true)
    expect(enabled.state).toBe("failed")
  })

  it("rejects restore for linked, unknown, and never-updated managed plugins", async () => {
    const linked = makeManager()
    await expect(linked.manager.restore("owner.example")).rejects.toThrow("linked")
    await expect(linked.manager.restore("owner.ghost")).rejects.toThrow("not installed")

    renameSync(join(linked.root, "example"), join(linked.root, "owner.example"))
    writeFileSync(
      join(linked.root, "owner.example", MANAGED_PLUGIN_MARKER),
      MANAGED_PLUGIN_MARKER_CONTENT
    )
    await expect(linked.manager.restore("owner.example")).rejects.toThrow("no known-good")
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
