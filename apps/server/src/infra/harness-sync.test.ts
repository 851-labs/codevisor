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
  const calls: World["calls"] = { enabled: [], installs: [], replaced: [] }
  const state: World["state"] = { harnesses: [], customs: [], installFailures: {} }
  const deps: HarnessSyncDeps = {
    db: services.db,
    serverId,
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
  it("publishes local catalog state and custom specs, idempotently", async () => {
    const world = await makeWorld("server-a")
    world.state.harnesses = [
      { id: "claude", enabled: true, installed: true, authenticated: true },
      { id: "codex", enabled: false, installed: false, authenticated: true }
    ]
    world.state.customs = [
      { id: "mybot", name: "My Bot", command: "mybot", args: ["--acp"], env: { B: "2", A: "1" } },
      { id: "tinybot", name: "Tiny", command: "tinybot" }
    ]

    const first = await reconcileHarnesses(world.deps)
    expect([...first.status.published].sort()).toEqual([
      "claude",
      "codex",
      "custom:mybot",
      "custom:tinybot"
    ])
    // Env keys serialize sorted, so fingerprints are author-independent.
    const mybot = first.changedEntries.find((entry) => entry.key === "custom:mybot")
    expect(JSON.stringify(mybot?.value)).toContain('"env":{"A":"1","B":"2"}')
    expect(first.changedEntries.find((entry) => entry.key === "claude")?.value).toEqual({
      enabled: true,
      installed: true
    })

    expect((await reconcileHarnesses(world.deps)).status).toEqual({
      published: [],
      applied: [],
      removed: [],
      installing: [],
      blocked: []
    })
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

    // Pass 1: nothing publishes (the fleet wins first contact); the enabled
    // set applies, installs start, the custom spec lands.
    const first = await reconcileHarnesses(world.deps)
    expect(first.status.published).toEqual([])
    expect(world.calls.enabled).toEqual([["claude", false]])
    expect([...first.status.installing].sort()).toEqual(["claude", "codex"])
    expect(first.status.applied).toEqual(["custom:mybot"])
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

    // Pass 3: binaries arrived — the applied record finally lands, and
    // still nothing publishes back.
    world.state.installFailures = {}
    world.state.harnesses = world.state.harnesses.map((harness) => ({
      ...harness,
      installed: true
    }))
    const third = await reconcileHarnesses(world.deps)
    expect([...third.status.applied].sort()).toEqual(["claude", "codex"])
    expect(third.status.published).toEqual([])
    expect(third.changedEntries).toEqual([])
  })

  it("auth-gates enables until the machine signs in", async () => {
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
    expect(first.status.blocked).toEqual([
      { id: "claude", reason: "Sign in before this harness can be enabled" }
    ])
    expect(world.calls.enabled).toEqual([])

    world.state.harnesses = [{ id: "claude", enabled: false, installed: true, authenticated: true }]
    const second = await reconcileHarnesses(world.deps)
    expect(world.calls.enabled).toEqual([["claude", true]])
    expect(second.status.applied).toEqual(["claude"])

    // A local edit after adoption publishes — with the fleet's installed
    // flag preserved even if the local binary state disagrees.
    world.state.harnesses = [
      { id: "claude", enabled: false, installed: false, authenticated: true }
    ]
    const third = await reconcileHarnesses(world.deps)
    expect(third.status.published).toEqual(["claude"])
    expect(third.changedEntries.find((entry) => entry.key === "claude")?.value).toEqual({
      enabled: false,
      installed: true
    })
  })

  it("tombstones custom deletions and applies fleet tombstones", async () => {
    const world = await makeWorld("server-d")
    world.state.customs = [{ id: "mybot", name: "My Bot", command: "mybot" }]
    await reconcileHarnesses(world.deps)

    world.state.customs = []
    const deleted = await reconcileHarnesses(world.deps)
    expect(deleted.status.published).toEqual(["custom:mybot"])
    expect(deleted.changedEntries.find((entry) => entry.key === "custom:mybot")?.deleted).toBe(true)

    // On another machine: the live spec applies, then the tombstone removes.
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
    expect(other.state.customs).toEqual([])
    expect(other.calls.replaced.at(-1)).toEqual([])
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
        // Malformed catalog value for a LOCAL harness, stamped far future so
        // the local publish loses and the apply loop must skip it.
        { key: "codex", value: "junk", timestamp: at(future) },
        { key: "half", value: { enabled: true }, timestamp: at(10) },
        { key: "bad-enabled", value: { enabled: "yes", installed: true }, timestamp: at(10) },
        { key: "nothing", value: null, timestamp: at(10) },
        // A harness this machine has never heard of: valid, but skipped.
        { key: "unknown-harness", value: { enabled: true, installed: true }, timestamp: at(10) },
        // A tombstoned catalog id for a local harness: publishes right over.
        { key: "ghost", value: null, deleted: true, timestamp: at(10) },
        // One whose tombstone outlives the republish attempt entirely.
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
    // ghost resurrects over its tombstone; codex and zombie republish
    // attempts lose to the future stamps, so nothing actually changed.
    expect([...result.status.published].sort()).toEqual(["bad-enabled", "ghost", "half", "zombie"])
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
