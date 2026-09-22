import type { CustomHarnessSpec } from "@codevisor/api"
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
    readonly replaced: Array<ReadonlyArray<CustomHarnessSpec>>
  }
  readonly state: {
    harnesses: Array<LocalHarnessState>
    customs: Array<CustomHarnessSpec>
    installFailures: Record<string, unknown>
  }
}

const makeWorld = async (serverId: string): Promise<World> => {
  const { services } = await makeServices(serverId)
  const calls: World["calls"] = { enabled: [], installs: [], uninstalls: [], replaced: [] }
  const state: World["state"] = { harnesses: [], customs: [], installFailures: {} }
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
    },
    listCustomSpecs: () => Promise.resolve([...state.customs]),
    replaceCustomSpecs: (specs) => {
      calls.replaced.push([...specs])
      state.customs = [...specs]
      return Promise.resolve()
    }
  }
  return { deps, calls, state }
}

describe("harness sync", () => {
  it("promotes what a machine already runs into the catalog; idle CLIs and local custom definitions stay out", async () => {
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
      // A user-defined ACP harness: lives in the catalog as a `custom:` spec
      // row, never as a plain preference row.
      { id: "mybot", source: "custom", enabled: true, installed: true, authenticated: true },
      // No display identity reported: the row still lands; clients name it.
      { id: "goose", enabled: true, installed: true, authenticated: true }
    ]
    world.state.customs = [
      { id: "mybot", name: "My Bot", command: "mybot", args: ["--acp"], env: { B: "2", A: "1" } },
      { id: "tinybot", name: "Tiny", command: "tinybot" }
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
        { key: "codex", value: { enabled: true, installed: true }, timestamp: at(11) },
        {
          key: "custom:mybot",
          value: { id: "mybot", name: "My Bot", command: "mybot" },
          timestamp: at(12)
        }
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
    expect([...first.status.installing].sort()).toEqual(["claude", "codex"])
    expect(first.status.applied).toEqual(["claude", "custom:mybot"])
    expect(world.calls.replaced.at(-1)?.map((spec) => spec.id)).toEqual(["mybot"])

    // Pass 2: installs still running — refusals surface as blocked (Error
    // and non-Error shapes both), and nothing is recorded yet.
    world.state.installFailures = {
      claude: new Error("install already running"),
      codex: "no runnable method"
    }
    const second = await reconcileHarnesses(world.deps)
    expect(second.status.installing).toEqual([])
    expect([...second.status.blocked].map((item) => item.reason).sort()).toEqual([
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

  it("reports unavailable uninstall and preserves locally edited custom definitions", async () => {
    const world = await makeWorld("uninstall-blocked")
    world.state.harnesses = [{ id: "claude", enabled: false, installed: true, authenticated: true }]
    await run(
      world.deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        {
          key: "claude",
          value: { enabled: false, installed: false, uninstall: true },
          timestamp: at(10)
        },
        {
          key: "custom:bot",
          value: { id: "bot", name: "Global", command: "global" },
          timestamp: at(10)
        }
      ])
    )
    world.state.customs = [{ id: "bot", name: "Local", command: "local" }]
    await run(
      world.deps.db.mergeSyncEntries("local.harness-custom-overrides", [
        { key: "bot", value: true, timestamp: at(10) }
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
    expect(world.state.customs[0]?.name).toBe("Local")
    // Forgetting the local edit lets the shared definition apply again.
    await run(
      world.deps.db.mergeSyncEntries("local.harness-custom-overrides", [
        { key: "bot", value: null, deleted: true, timestamp: at(20) }
      ])
    )
    await reconcileHarnesses(world.deps)
    expect(world.state.customs[0]?.name).toBe("Global")
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

  it("keeps local custom deletions local and applies explicit global tombstones", async () => {
    const world = await makeWorld("server-d")
    world.state.customs = [{ id: "mybot", name: "My Bot", command: "mybot" }]
    await reconcileHarnesses(world.deps)

    world.state.customs = []
    const deleted = await reconcileHarnesses(world.deps)
    expect(deleted.status.published).toEqual([])
    expect(deleted.changedEntries).toEqual([])

    // On another machine: the live spec applies, then the tombstone stops managing it.
    const other = await makeWorld("server-e")
    await run(
      other.deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        {
          key: "custom:mybot",
          value: { id: "mybot", name: "My Bot", command: "mybot" },
          timestamp: at(10)
        }
      ])
    )
    await reconcileHarnesses(other.deps)
    expect(other.state.customs.map((spec) => spec.id)).toEqual(["mybot"])
    await run(
      other.deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        { key: "custom:mybot", value: null, deleted: true, timestamp: at(20) }
      ])
    )
    const removed = await reconcileHarnesses(other.deps)
    expect(removed.status.removed).toEqual(["custom:mybot"])
    expect(other.state.customs.map((spec) => spec.id)).toEqual(["mybot"])
    expect(other.calls.replaced).toHaveLength(1)
  })

  it("adopts the fleet's spec on a first-contact custom collision", async () => {
    const world = await makeWorld("server-f")
    world.state.customs = [{ id: "mybot", name: "Local Flavor", command: "mybot-local" }]
    await run(
      world.deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        {
          key: "custom:mybot",
          value: { id: "mybot", name: "Fleet Flavor", command: "mybot" },
          timestamp: at(10)
        }
      ])
    )

    const result = await reconcileHarnesses(world.deps)
    expect(result.status.published).toEqual([])
    expect(result.status.applied).toEqual(["custom:mybot"])
    expect(world.state.customs[0]?.name).toBe("Fleet Flavor")
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
    world.state.customs = []
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
        { key: "departed", value: null, deleted: true, timestamp: at(10) },
        // Custom junk in every flavor.
        { key: "custom:str", value: "nope", timestamp: at(10) },
        { key: "custom:noid", value: { name: "x", command: "x" }, timestamp: at(10) },
        { key: "custom:noname", value: { id: "noname", command: "x" }, timestamp: at(10) },
        { key: "custom:nocmd", value: { id: "nocmd", name: "x" }, timestamp: at(10) },
        {
          key: "custom:mismatch",
          value: { id: "other", name: "x", command: "x" },
          timestamp: at(10)
        },
        {
          key: "custom:messy",
          value: {
            id: "messy",
            name: "Messy",
            command: "messy",
            args: ["keep", 42],
            env: { GOOD: "1", BAD: 2 }
          },
          timestamp: at(10)
        },
        // A custom tombstone for a spec this machine never had: no-op.
        { key: "custom:never", value: null, deleted: true, timestamp: at(10) }
      ])
    )

    // A custom spec this machine once applied whose replica entry is
    // ALREADY a tombstone (nothing to republish), and a codex applied
    // record matching local state exactly — so the junk replica entry is
    // never overwritten and must be skipped at apply time.
    await run(
      world.deps.db.mergeSyncEntries("local.harnesses-applied", [
        { key: "custom:never", value: "stale-fp", timestamp: at(5) },
        {
          key: "codex",
          value: JSON.stringify({ enabled: true, installed: true }),
          timestamp: at(6)
        }
      ])
    )

    const result = await reconcileHarnesses(world.deps)
    // Only the valid custom definition applies; nothing publishes back.
    expect(result.status.published).toEqual([])
    expect(result.status.applied).toEqual(["custom:messy"])
    expect(result.status.removed).toEqual([])
    // The messy-but-valid spec applied with junk fields filtered.
    expect(world.state.customs.map((spec) => spec.id)).toEqual(["messy"])
    expect(world.state.customs[0]?.args).toEqual(["keep"])
    expect(world.state.customs[0]?.env).toEqual({ GOOD: "1" })
    expect(world.calls.enabled).toEqual([])
    expect(world.calls.installs).toEqual([])
  })
})
