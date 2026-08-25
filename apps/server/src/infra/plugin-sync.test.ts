import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { makeServices, run, tempDirs } from "../test-support.js"
import {
  PLUGINS_SYNC_NAMESPACE,
  pluginSyncOrigin,
  reconcilePlugins,
  type LocalPluginState,
  type PluginSyncDeps
} from "./plugin-sync.js"

const at = (wallMs: number) => ({ wallMs, counter: 0, deviceId: "elsewhere" })

interface World {
  readonly deps: PluginSyncDeps
  readonly calls: {
    readonly enabled: Array<readonly [string, boolean]>
    readonly installs: Array<string>
    readonly removals: Array<string>
  }
  readonly state: {
    plugins: Array<LocalPluginState>
    installFailure?: unknown
    removeFailure?: unknown
  }
}

const makeWorld = async (serverId: string): Promise<World> => {
  const { services } = await makeServices(serverId)
  const calls: World["calls"] = { enabled: [], installs: [], removals: [] }
  const state: World["state"] = { plugins: [] }
  const deps: PluginSyncDeps = {
    db: services.db,
    serverId,
    listPlugins: () => Promise.resolve([...state.plugins]),
    installFromSource: (source) => {
      if (state.installFailure !== undefined) return Promise.reject(state.installFailure as Error)
      calls.installs.push(source)
      return Promise.resolve()
    },
    setEnabled: (pluginId, enabled) => {
      calls.enabled.push([pluginId, enabled])
      state.plugins = state.plugins.map((plugin) =>
        plugin.id === pluginId ? { ...plugin, enabled } : plugin
      )
      return Promise.resolve()
    },
    removePlugin: (pluginId) => {
      if (state.removeFailure !== undefined) return Promise.reject(state.removeFailure as Error)
      calls.removals.push(pluginId)
      state.plugins = state.plugins.filter((plugin) => plugin.id !== pluginId)
      return Promise.resolve()
    }
  }
  return { deps, calls, state }
}

describe("plugin sync", () => {
  it("publishes registry-sourced plugins only, idempotently", async () => {
    const world = await makeWorld("server-a")
    world.state.plugins = [
      { id: "acme.tunes", enabled: true, origin: "acme/tunes" },
      { id: "dev.local", enabled: true },
      { id: "acme.paused", enabled: false, origin: "acme/paused" }
    ]

    const first = await reconcilePlugins(world.deps)
    expect([...first.status.published].sort()).toEqual(["acme.paused", "acme.tunes"])
    expect(first.changedEntries.find((entry) => entry.key === "acme.tunes")?.value).toEqual({
      enabled: true,
      source: "acme/tunes"
    })

    expect((await reconcilePlugins(world.deps)).status).toEqual({
      published: [],
      applied: [],
      removed: [],
      installed: [],
      blocked: []
    })
  })

  it("installs missing plugins from their source, retrying past failures", async () => {
    const world = await makeWorld("server-b")
    await run(
      world.deps.db.mergeSyncEntries(PLUGINS_SYNC_NAMESPACE, [
        { key: "acme.tunes", value: { enabled: true, source: "acme/tunes" }, timestamp: at(10) },
        { key: "acme.paused", value: { enabled: false, source: "acme/paused" }, timestamp: at(11) }
      ])
    )

    // Pass 1: a requirement is missing — blocked, nothing recorded.
    world.state.installFailure = new Error("Required executable not found: ffmpeg")
    const first = await reconcilePlugins(world.deps)
    expect([...first.status.blocked].map((item) => item.reason)).toEqual([
      "Required executable not found: ffmpeg",
      "Required executable not found: ffmpeg"
    ])
    expect(first.status.installed).toEqual([])

    // Pass 2: the requirement appeared — both install, the disabled one is
    // disabled right after, and the applied records land.
    delete world.state.installFailure
    const second = await reconcilePlugins(world.deps)
    expect([...second.status.installed].sort()).toEqual(["acme.paused", "acme.tunes"])
    expect([...second.status.applied].sort()).toEqual(["acme.paused", "acme.tunes"])
    expect(world.calls.installs.sort()).toEqual(["acme/paused", "acme/tunes"])
    expect(world.calls.enabled).toEqual([["acme.paused", false]])
    expect(second.status.published).toEqual([])
  })

  it("adopts the fleet on first contact and syncs enabled drift both ways", async () => {
    const world = await makeWorld("server-c")
    await run(
      world.deps.db.mergeSyncEntries(PLUGINS_SYNC_NAMESPACE, [
        { key: "acme.tunes", value: { enabled: false, source: "acme/tunes" }, timestamp: at(10) }
      ])
    )
    // The plugin already exists locally, enabled — first contact defers.
    world.state.plugins = [{ id: "acme.tunes", enabled: true, origin: "acme/tunes" }]

    const first = await reconcilePlugins(world.deps)
    expect(first.status.published).toEqual([])
    expect(world.calls.enabled).toEqual([["acme.tunes", false]])
    expect(first.status.applied).toEqual(["acme.tunes"])

    // A local re-enable after adoption publishes back to the fleet.
    world.state.plugins = [{ id: "acme.tunes", enabled: true, origin: "acme/tunes" }]
    const second = await reconcilePlugins(world.deps)
    expect(second.status.published).toEqual(["acme.tunes"])
    expect(second.changedEntries.find((entry) => entry.key === "acme.tunes")?.value).toEqual({
      enabled: true,
      source: "acme/tunes"
    })

    // A fleet-side source move with the same enabled state re-records
    // without touching the plugin.
    const before = [...world.calls.enabled]
    await run(
      world.deps.db.mergeSyncEntries(PLUGINS_SYNC_NAMESPACE, [
        {
          key: "acme.tunes",
          value: { enabled: true, source: "acme/tunes-moved" },
          timestamp: at(30_000_000_000_000)
        }
      ])
    )
    const third = await reconcilePlugins(world.deps)
    expect(third.status.applied).toEqual(["acme.tunes"])
    expect(world.calls.enabled).toEqual(before)
  })

  it("tombstones local uninstalls and applies fleet tombstones", async () => {
    const world = await makeWorld("server-d")
    world.state.plugins = [{ id: "acme.tunes", enabled: true, origin: "acme/tunes" }]
    await reconcilePlugins(world.deps)

    world.state.plugins = []
    const deleted = await reconcilePlugins(world.deps)
    expect(deleted.status.published).toEqual(["acme.tunes"])
    expect(deleted.changedEntries.find((entry) => entry.key === "acme.tunes")?.deleted).toBe(true)
    // Idempotent: the tombstone does not republish.
    expect((await reconcilePlugins(world.deps)).status.published).toEqual([])

    // Another machine with the plugin applied: a refused uninstall blocks
    // and retries, then the removal lands.
    const other = await makeWorld("server-e")
    other.state.plugins = [{ id: "acme.tunes", enabled: true, origin: "acme/tunes" }]
    await reconcilePlugins(other.deps)
    await run(
      other.deps.db.mergeSyncEntries(PLUGINS_SYNC_NAMESPACE, [
        { key: "acme.tunes", value: null, deleted: true, timestamp: at(20_000_000_000_000) }
      ])
    )
    other.state.removeFailure = "plugin has open panes"
    const refused = await reconcilePlugins(other.deps)
    expect(refused.status.blocked).toEqual([{ id: "acme.tunes", reason: "plugin has open panes" }])
    delete other.state.removeFailure
    const removed = await reconcilePlugins(other.deps)
    expect(removed.status.removed).toEqual(["acme.tunes"])
    expect(other.calls.removals).toEqual(["acme.tunes"])
    expect(other.state.plugins).toEqual([])
  })

  it("leaves sovereign local plugins alone and skips malformed entries", async () => {
    const world = await makeWorld("server-f")
    const future = 10_000_000_000_000
    // A LINKED plugin sharing an id with a fleet entry stays untouched.
    world.state.plugins = [{ id: "acme.tunes", enabled: true }]
    await run(
      world.deps.db.mergeSyncEntries(PLUGINS_SYNC_NAMESPACE, [
        { key: "acme.tunes", value: { enabled: false, source: "acme/tunes" }, timestamp: at(10) },
        { key: "junk", value: "nope", timestamp: at(future) },
        { key: "half", value: { enabled: true }, timestamp: at(10) },
        { key: "bad-enabled", value: { enabled: "yes", source: "x/y" }, timestamp: at(10) },
        { key: "nothing", value: null, timestamp: at(10) },
        // A tombstone for a plugin this machine never had: no-op.
        { key: "ghost", value: null, deleted: true, timestamp: at(10) }
      ])
    )
    // One this machine once applied whose replica entry is ALREADY a
    // tombstone: nothing to republish either.
    await run(
      world.deps.db.mergeSyncEntries("local.plugins-applied", [
        { key: "ghost", value: "stale-fp", timestamp: at(5) }
      ])
    )

    const result = await reconcilePlugins(world.deps)
    expect(world.calls.enabled).toEqual([])
    expect(result.status.applied).toEqual([])
    expect(result.status.removed).toEqual([])
    // The malformed entries with sources never became installs either.
    expect(world.calls.installs).toEqual([])
  })

  it("derives sync origins from install receipts", () => {
    const receiptDir = (receipt: unknown): string => {
      const dir = mkdtempSync(join(tmpdir(), "plugin-receipt-"))
      tempDirs.push(dir)
      if (receipt !== undefined) {
        writeFileSync(join(dir, ".codevisor-install.json"), JSON.stringify(receipt))
      }
      return dir
    }
    const base = {
      schemaVersion: 1,
      pluginId: "acme.tunes",
      resolvedCommit: "a".repeat(40),
      installedVersion: "1.0.0",
      installedAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z"
    }

    expect(
      pluginSyncOrigin(
        receiptDir({
          ...base,
          source: {
            kind: "github",
            url: "https://github.com/acme/tunes",
            repo: "acme/tunes",
            tracking: "registry"
          }
        })
      )
    ).toBe("acme/tunes")
    expect(
      pluginSyncOrigin(
        receiptDir({
          ...base,
          source: { kind: "github", url: "https://github.com/acme/tunes", tracking: "registry" }
        })
      )
    ).toBe("https://github.com/acme/tunes")
    expect(
      pluginSyncOrigin(
        receiptDir({
          ...base,
          source: { kind: "git", url: "https://example.com/tunes.git", tracking: "pinned" }
        })
      )
    ).toBe("https://example.com/tunes.git")
    expect(
      pluginSyncOrigin(
        receiptDir({
          ...base,
          source: { kind: "local", url: "/home/dev/tunes", tracking: "pinned" }
        })
      )
    ).toBeUndefined()
    expect(pluginSyncOrigin(receiptDir(undefined))).toBeUndefined()
  })
})
