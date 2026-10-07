import { describe, expect, it } from "vitest"

import { makeServices, run } from "../test-support.js"
import {
  HARNESSES_SYNC_NAMESPACE,
  reconcileHarnesses,
  type HarnessSyncDeps,
  type LocalHarnessState
} from "./harness-sync.js"

const at = (wallMs: number) => ({ wallMs, counter: 0, deviceId: "elsewhere" })

interface World {
  readonly deps: HarnessSyncDeps
  readonly calls: {
    readonly enabled: Array<readonly [string, boolean]>
    readonly installs: Array<string>
    readonly uninstalls: Array<string>
  }
  readonly state: {
    harnesses: Array<LocalHarnessState>
    installFailures: Record<string, unknown>
  }
}

const makeWorld = async (serverId: string): Promise<World> => {
  const { services } = await makeServices(serverId)
  const calls: World["calls"] = { enabled: [], installs: [], uninstalls: [] }
  const state: World["state"] = { harnesses: [], installFailures: {} }
  const deps: HarnessSyncDeps = {
    db: services.db,
    serverId,
    now: () => 1000,
    beginUninstall: async (id) => {
      calls.uninstalls.push(id)
    },
    listHarnesses: () => Promise.resolve([...state.harnesses]),
    setEnabled: (harnessId, enabled) => {
      calls.enabled.push([harnessId, enabled])
      state.harnesses = state.harnesses.map((harness) =>
        harness.id === harnessId ? { ...harness, enabled } : harness
      )
      return Promise.resolve()
    },
    beginInstall: (harnessId) => {
      const failure = state.installFailures[harnessId]
      if (failure !== undefined) return Promise.reject(failure as Error)
      calls.installs.push(harnessId)
      return Promise.resolve()
    }
  }
  return { deps, calls, state }
}

describe("harness sync", () => {
  it("promotes what a machine already runs into the catalog; idle CLIs stay out", async () => {
    const world = await makeWorld("server-a")
    world.state.harnesses = [
      {
        id: "claude",
        name: "Claude Code",
        symbolName: "sparkle",
        enabled: true,
        installed: true,
        authenticated: true
      },
      // Installed but never signed in: not something the user set up.
      { id: "cursor", enabled: true, installed: true, authenticated: false },
      // Installed and signed in but switched off locally.
      { id: "amp", enabled: false, installed: true, authenticated: true },
      { id: "codex", enabled: true, installed: false, authenticated: true },
      // No display identity reported: the row still lands; clients name it.
      { id: "goose", enabled: true, installed: true, authenticated: true }
    ]

    const first = await reconcileHarnesses(world.deps)
    expect(first.status.published).toEqual(["claude", "goose"])
    expect(first.changedEntries.map((entry) => entry.key).toSorted()).toEqual(["claude", "goose"])
    const entries = await run(world.deps.db.getSyncEntries(HARNESSES_SYNC_NAMESPACE))
    expect(entries.find((entry) => entry.key === "claude")).toMatchObject({
      value: {
        name: "Claude Code",
        symbolName: "sparkle",
        enabled: true,
        installed: true,
        uninstall: false
      },
      timestamp: { deviceId: "server-a" }
    })
    expect(entries.find((entry) => entry.key === "goose")?.value).toEqual({
      enabled: true,
      installed: true,
      uninstall: false
    })
    expect(entries.map((entry) => entry.key).toSorted()).toEqual(["claude", "goose"])

    // Promotion happens once; the row is now authored.
    expect((await reconcileHarnesses(world.deps)).status).toEqual({
      published: [],
      applied: [],
      removed: [],
      installing: [],
      blocked: []
    })
  })

  it("never promotes over an authored row, a tombstone, or an uninstall directive", async () => {
    const world = await makeWorld("server-authored")
    await run(
      world.deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        { key: "claude", value: { enabled: false, installed: true }, timestamp: at(10) },
        {
          key: "codex",
          value: { enabled: false, installed: false, uninstall: true },
          timestamp: at(11)
        },
        { key: "amp", value: null, deleted: true, timestamp: at(12) }
      ])
    )
    world.state.harnesses = [
      { id: "claude", enabled: true, installed: true, authenticated: true },
      { id: "codex", enabled: true, installed: true, authenticated: true },
      { id: "amp", enabled: true, installed: true, authenticated: true }
    ]
    const result = await reconcileHarnesses(world.deps)
    expect(result.status.published).toEqual([])
    expect(result.changedEntries).toEqual([])
    // The catalog wins over the machine's own state.
    expect(world.calls.enabled).toEqual([
      ["claude", false],
      ["codex", false]
    ])
    expect(world.calls.uninstalls).toEqual(["codex"])
  })

  it("first contact defers to the fleet: adopts, installs, and retries", async () => {
    const world = await makeWorld("server-b")
    await run(
      world.deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        { key: "claude", value: { enabled: false, installed: true }, timestamp: at(10) },
        { key: "codex", value: { enabled: true, installed: true }, timestamp: at(11) }
      ])
    )
    // A fresh machine: everything default-enabled, nothing installed.
    world.state.harnesses = [
      { id: "claude", enabled: true, installed: false, authenticated: true },
      { id: "codex", enabled: true, installed: false, authenticated: true }
    ]

    // Pass 1: shared settings apply without publishing local discoveries.
    const first = await reconcileHarnesses(world.deps)
    expect(first.status.published).toEqual([])
    expect(world.calls.enabled).toEqual([["claude", false]])
    expect([...first.status.installing].toSorted()).toEqual(["claude", "codex"])
    expect(first.status.applied).toEqual(["claude"])

    // Pass 2: installs still running — refusals surface as blocked (Error
    // and non-Error shapes both), and nothing is recorded yet.
    world.state.installFailures = {
      claude: new Error("install already running"),
      codex: "no runnable method"
    }
    const second = await reconcileHarnesses(world.deps)
    expect(second.status.installing).toEqual([])
    expect([...second.status.blocked].map((item) => item.reason).toSorted()).toEqual([
      "install already running",
      "no runnable method"
    ])

    // Pass 3: installed binaries satisfy the desired state.
    world.state.installFailures = {}
    world.state.harnesses = world.state.harnesses.map((harness) => ({
      ...harness,
      installed: true
    }))
    const third = await reconcileHarnesses(world.deps)
    expect(third.status.applied).toEqual([])
    expect(third.status.published).toEqual([])
    expect(third.changedEntries).toEqual([])
  })

  it("retains desired enablement while authentication is pending", async () => {
    const world = await makeWorld("server-c")
    await run(
      world.deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        { key: "claude", value: { enabled: true, installed: true }, timestamp: at(10) }
      ])
    )
    world.state.harnesses = [
      { id: "claude", enabled: false, installed: true, authenticated: false }
    ]
    const first = await reconcileHarnesses(world.deps)
    expect(first.status.blocked).toEqual([{ id: "claude", reason: "Sign in required" }])
    expect(world.calls.enabled).toEqual([["claude", true]])
    world.state.harnesses[0] = { id: "claude", enabled: true, installed: true, authenticated: true }
    expect((await reconcileHarnesses(world.deps)).status.blocked).toEqual([])
    expect(await run(world.deps.db.getSyncEntries(HARNESSES_SYNC_NAMESPACE))).toMatchObject([
      { value: { enabled: true, installed: true } }
    ])
  })

  it("follows the catalog even when a stale machine-local override row is present", async () => {
    // Rows left behind by the retired override layer (an old uninstall on
    // this machine) must not shadow a catalog that later re-enabled the harness.
    const world = await makeWorld("server-local")
    world.state.harnesses = [{ id: "grok", enabled: false, installed: true, authenticated: true }]
    await run(
      world.deps.db.mergeSyncEntries("local.harness-overrides", [
        { key: "grok", value: { enabled: false, installed: false }, timestamp: at(5) }
      ])
    )
    await run(
      world.deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        { key: "grok", value: { enabled: true, installed: true }, timestamp: at(10) }
      ])
    )
    await reconcileHarnesses(world.deps)
    expect(world.calls.enabled).toEqual([["grok", true]])
    expect(world.calls.uninstalls).toEqual([])
  })

  it("reports an unavailable or failing uninstall as blocked", async () => {
    const world = await makeWorld("uninstall-blocked")
    world.state.harnesses = [{ id: "claude", enabled: false, installed: true, authenticated: true }]
    await run(
      world.deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        {
          key: "claude",
          value: { enabled: false, installed: false, uninstall: true },
          timestamp: at(10)
        }
      ])
    )
    const { beginUninstall: _omitted, ...withoutUninstall } = world.deps
    expect((await reconcileHarnesses(withoutUninstall)).status.blocked).toEqual([
      { id: "claude", reason: "Uninstall unavailable on this machine" }
    ])
    expect(
      (await reconcileHarnesses({ ...world.deps, beginUninstall: () => Promise.reject("Busy") }))
        .status.blocked
    ).toEqual([{ id: "claude", reason: "Busy" }])
  })

  it("never treats legacy absence as permission to uninstall", async () => {
    const world = await makeWorld("legacy")
    world.state.harnesses = [{ id: "claude", enabled: true, installed: true, authenticated: true }]
    await run(
      world.deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        { key: "claude", value: { enabled: false, installed: false }, timestamp: at(10) }
      ])
    )
    await reconcileHarnesses(world.deps)
    expect(world.calls.uninstalls).toEqual([])
    expect(world.calls.enabled).toEqual([])
  })

  it("does not start operations while a lifecycle operation is running", async () => {
    const world = await makeWorld("busy")
    world.state.harnesses = [
      { id: "claude", enabled: true, installed: false, authenticated: true, phase: "installing" }
    ]
    await run(
      world.deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        { key: "claude", value: { enabled: true, installed: true }, timestamp: at(10) }
      ])
    )
    await reconcileHarnesses(world.deps)
    expect(world.calls.installs).toEqual([])
  })

  it("never lets malformed or foreign entries drive changes", async () => {
    const world = await makeWorld("server-g")
    const future = 10_000_000_000_000
    world.state.harnesses = [
      { id: "codex", enabled: true, installed: true, authenticated: true },
      { id: "ghost", enabled: true, installed: true, authenticated: true },
      { id: "half", enabled: true, installed: true, authenticated: true },
      { id: "bad-enabled", enabled: true, installed: true, authenticated: true },
      { id: "zombie", enabled: true, installed: true, authenticated: true }
    ]
    await run(
      world.deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        // Malformed catalog values cannot authorize changes.
        { key: "codex", value: "junk", timestamp: at(future) },
        { key: "half", value: { enabled: true }, timestamp: at(10) },
        { key: "bad-enabled", value: { enabled: "yes", installed: true }, timestamp: at(10) },
        { key: "nothing", value: null, timestamp: at(10) },
        // A harness this machine has never heard of: valid, but skipped.
        { key: "unknown-harness", value: { enabled: true, installed: true }, timestamp: at(10) },
        // Tombstones stop managing installed local harnesses.
        { key: "ghost", value: null, deleted: true, timestamp: at(10) },
        // Future timestamps never resurrect deleted settings.
        { key: "zombie", value: null, deleted: true, timestamp: at(future) },
        // A tombstone for a harness this machine does not even have.
        { key: "departed", value: null, deleted: true, timestamp: at(10) }
      ])
    )

    const result = await reconcileHarnesses(world.deps)
    expect(result.status.published).toEqual([])
    expect(result.status.applied).toEqual([])
    expect(world.calls.enabled).toEqual([])
    expect(world.calls.installs).toEqual([])
  })
})
