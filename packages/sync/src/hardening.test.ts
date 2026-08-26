/// Phase 15: ownership-model hardening. These tests pin the LWW core's
/// behavior under the ugly cases every later phase leans on: three-replica
/// races, skewed clocks, partition-then-merge, and tombstone resurrection
/// attempts. The "conformance vector" scenario is mirrored verbatim in
/// SyncClockHardeningTests.swift — both implementations MUST converge to
/// the same document or replicas diverge across the fleet.
import { describe, expect, it } from "vitest"
import {
  compareSyncTimestamps,
  latestSyncTimestamp,
  mergeSyncEntries,
  nextSyncTimestamp,
  type SyncEntryRecord,
  type SyncTimestampValue
} from "./index.js"

const ts = (wallMs: number, counter: number, deviceId: string): SyncTimestampValue => ({
  wallMs,
  counter,
  deviceId
})

const entry = (key: string, value: unknown, timestamp: SyncTimestampValue): SyncEntryRecord => ({
  key,
  value,
  timestamp
})

const dead = (key: string, timestamp: SyncTimestampValue): SyncEntryRecord => ({
  key,
  value: null,
  deleted: true,
  timestamp
})

/// The shared conformance vector: three replicas that exercised every
/// tiebreak rung (wall clock, counter, device id) plus a tombstone and a
/// deliberate revival. Mirrored in SyncClockHardeningTests.swift.
const batchAlpha = [
  entry("theme", "dark", ts(100, 0, "alpha")),
  entry("font", "mono", ts(120, 0, "alpha")),
  dead("channel", ts(140, 0, "alpha"))
]
const batchBeta = [
  entry("theme", "light", ts(100, 0, "beta")),
  entry("channel", "alpha-build", ts(130, 0, "beta")),
  entry("scale", 2, ts(90, 0, "beta"))
]
const batchGamma = [
  entry("font", "serif", ts(120, 1, "gamma")),
  entry("scale", 3, ts(90, 0, "gamma")),
  entry("channel", "beta-build", ts(150, 0, "gamma"))
]
const expectedConvergence = [
  entry("channel", "beta-build", ts(150, 0, "gamma")),
  entry("font", "serif", ts(120, 1, "gamma")),
  entry("scale", 3, ts(90, 0, "gamma")),
  entry("theme", "light", ts(100, 0, "beta"))
]

const permutations = <T>(items: ReadonlyArray<T>): Array<Array<T>> => {
  if (items.length <= 1) return [[...items]]
  return items.flatMap((head, index) =>
    permutations([...items.slice(0, index), ...items.slice(index + 1)]).map((rest) =>
      [head].concat(rest)
    )
  )
}

describe("three-replica convergence", () => {
  it("reaches the same document in every gossip order (conformance vector)", () => {
    for (const order of permutations([batchAlpha, batchBeta, batchGamma])) {
      let document: ReadonlyArray<SyncEntryRecord> = []
      for (const batch of order) {
        document = mergeSyncEntries(document, batch).merged
      }
      expect(document).toEqual(expectedConvergence)
    }
  })

  it("is associative: pre-merging any pair first changes nothing", () => {
    const pairFirst = mergeSyncEntries(
      mergeSyncEntries(batchBeta, batchGamma).merged,
      batchAlpha
    ).merged
    expect(pairFirst).toEqual(expectedConvergence)
  })

  it("republishing only the changed set still converges a fourth replica", () => {
    // A replica that merges everything relays just `changed` onward; a
    // fresh replica fed only those relays must still reach convergence.
    let document: ReadonlyArray<SyncEntryRecord> = []
    const relayed: Array<SyncEntryRecord> = []
    for (const batch of [batchAlpha, batchBeta, batchGamma]) {
      const result = mergeSyncEntries(document, batch)
      document = result.merged
      relayed.push(...result.changed)
    }
    expect(mergeSyncEntries([], relayed).merged).toEqual(expectedConvergence)
  })

  it("gossip reaches a fixpoint: converged replicas exchange nothing", () => {
    const replicas = [batchAlpha, batchBeta, batchGamma].map(
      (batch) => mergeSyncEntries([], batch).merged
    )
    // Full mesh, two rounds: after the first, every pairwise exchange is
    // silent — no churn, no oscillation.
    let exchanges = 0
    for (let round = 0; round < 2; round += 1) {
      exchanges = 0
      for (let from = 0; from < replicas.length; from += 1) {
        for (let to = 0; to < replicas.length; to += 1) {
          if (from === to) continue
          const source = replicas[from] ?? []
          const result = mergeSyncEntries(replicas[to] ?? [], source)
          replicas[to] = result.merged
          exchanges += result.changed.length
        }
      }
    }
    expect(exchanges).toBe(0)
    for (const replica of replicas) {
      expect(replica).toEqual(expectedConvergence)
    }
  })
})

describe("clock skew", () => {
  it("a device hours behind still wins its causally-later edits", () => {
    // "slow" has a wall clock of 500 while the fleet is at 1_000_000.
    const remote = entry("k", "fleet", ts(1_000_000, 0, "fast"))
    let document = mergeSyncEntries([], [remote]).merged
    // Its edit AFTER seeing the fleet value ratchets past it: same wall
    // clock, bumped counter — newer on every replica despite the skew.
    const stamp = nextSyncTimestamp("slow", latestSyncTimestamp(document), 500)
    expect(stamp).toEqual(ts(1_000_000, 1, "slow"))
    document = mergeSyncEntries(document, [entry("k", "local", stamp)]).merged
    expect(document).toEqual([entry("k", "local", stamp)])
    // And the fleet adopts it too — the skewed device is not second-class.
    expect(mergeSyncEntries([remote], [entry("k", "local", stamp)]).changed).toHaveLength(1)
  })

  it("a device hours ahead cannot be outrun, only ratcheted past", () => {
    const future = entry("k", "from-the-future", ts(9_000_000, 4, "ahead"))
    const document = mergeSyncEntries([], [future]).merged
    // A same-millisecond honest write loses; only a causally-later write
    // (stamped after seeing the future entry) wins.
    const blind = entry("k", "blind", ts(1_000_000, 0, "honest"))
    expect(mergeSyncEntries(document, [blind]).changed).toEqual([])
    const informed = nextSyncTimestamp("honest", latestSyncTimestamp(document), 1_000_000)
    expect(informed).toEqual(ts(9_000_000, 5, "honest"))
    expect(compareSyncTimestamps(informed, future.timestamp)).toBeGreaterThan(0)
  })

  it("counters disambiguate a burst of writes inside one millisecond", () => {
    let clock: SyncTimestampValue | undefined
    const burst: Array<SyncEntryRecord> = []
    for (const value of ["a", "b", "c"]) {
      clock = nextSyncTimestamp("dev", clock, 777)
      burst.push(entry("k", value, clock))
    }
    expect(burst.map((item) => item.timestamp.counter)).toEqual([0, 1, 2])
    // Merged in any order, the last write of the burst wins.
    expect(mergeSyncEntries([], burst.toReversed()).merged).toEqual([burst[2]])
    expect(mergeSyncEntries([], burst).merged).toEqual([burst[2]])
  })
})

describe("partition then merge", () => {
  it("both sides converge identically after a heal, in either push order", () => {
    // Shared history, then a partition: each side edits the same keys
    // several times, keeping only its latest state (LWW documents carry
    // no history — the heal exchanges final documents, not logs).
    const shared = [entry("mode", "auto", ts(10, 0, "seed"))]
    const sideA = mergeSyncEntries(shared, [
      entry("mode", "manual", ts(20, 0, "a")),
      entry("mode", "hybrid", ts(30, 0, "a")),
      entry("added-during-split", true, ts(25, 0, "a"))
    ]).merged
    const sideB = mergeSyncEntries(shared, [
      entry("mode", "off", ts(28, 0, "b")),
      dead("added-during-split", ts(40, 0, "b"))
    ]).merged
    const healAB = mergeSyncEntries(sideA, sideB).merged
    const healBA = mergeSyncEntries(sideB, sideA).merged
    expect(healAB).toEqual(healBA)
    expect(healAB).toEqual([
      dead("added-during-split", ts(40, 0, "b")),
      entry("mode", "hybrid", ts(30, 0, "a"))
    ])
  })
})

describe("tombstone resurrection attempts", () => {
  const tombstone = dead("mcp", ts(100, 0, "deleter"))

  it("a stale replica's live value never revives a deletion", () => {
    const result = mergeSyncEntries([tombstone], [entry("mcp", "zombie", ts(90, 0, "stale"))])
    expect(result.changed).toEqual([])
    expect(result.merged).toEqual([tombstone])
  })

  it("replaying the exact pre-delete history changes nothing", () => {
    const history = [
      entry("mcp", "v1", ts(50, 0, "author")),
      entry("mcp", "v2", ts(80, 2, "author"))
    ]
    const result = mergeSyncEntries([tombstone], history)
    expect(result.changed).toEqual([])
    expect(result.merged).toEqual([tombstone])
  })

  it("a tombstone reaches replicas that never saw the key at all", () => {
    const result = mergeSyncEntries([], [tombstone])
    expect(result.merged).toEqual([tombstone])
    // ...and keeps suppressing stale writes that arrive afterwards.
    expect(mergeSyncEntries(result.merged, [entry("mcp", "late", ts(99, 9, "z"))]).changed).toEqual(
      []
    )
  })

  it("dueling tombstones resolve deterministically like any write", () => {
    const rival = dead("mcp", ts(100, 0, "zeta"))
    expect(mergeSyncEntries([tombstone], [rival]).merged).toEqual([rival])
    expect(mergeSyncEntries([rival], [tombstone]).merged).toEqual([rival])
  })

  it("a deliberate causally-later re-add revives the key — by design", () => {
    const stamp = nextSyncTimestamp("author", latestSyncTimestamp([tombstone]), 100)
    const revived = entry("mcp", "reborn", stamp)
    const result = mergeSyncEntries([tombstone], [revived])
    expect(result.merged).toEqual([revived])
    // The revival also beats the tombstone on replicas merging the other
    // way around.
    expect(mergeSyncEntries([revived], [tombstone]).merged).toEqual([revived])
  })
})
