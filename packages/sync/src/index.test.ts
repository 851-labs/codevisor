import { describe, expect, it } from "vitest"
import {
  compareSyncTimestamps,
  isValidSyncNamespace,
  latestSyncTimestamp,
  mergeSyncEntries,
  nextSyncTimestamp,
  type SyncEntryRecord,
  type SyncTimestampValue
} from "./index.js"

const ts = (wallMs: number, counter = 0, deviceId = "a"): SyncTimestampValue => ({
  wallMs,
  counter,
  deviceId
})

const entry = (key: string, value: unknown, timestamp: SyncTimestampValue): SyncEntryRecord => ({
  key,
  value,
  timestamp
})

describe("compareSyncTimestamps", () => {
  it("orders by wall clock, then counter, then device id", () => {
    expect(compareSyncTimestamps(ts(1), ts(2))).toBeLessThan(0)
    expect(compareSyncTimestamps(ts(2), ts(1))).toBeGreaterThan(0)
    expect(compareSyncTimestamps(ts(1, 0), ts(1, 1))).toBeLessThan(0)
    expect(compareSyncTimestamps(ts(1, 1), ts(1, 0))).toBeGreaterThan(0)
    expect(compareSyncTimestamps(ts(1, 0, "a"), ts(1, 0, "b"))).toBeLessThan(0)
    expect(compareSyncTimestamps(ts(1, 0, "b"), ts(1, 0, "a"))).toBeGreaterThan(0)
    expect(compareSyncTimestamps(ts(1, 0, "a"), ts(1, 0, "a"))).toBe(0)
  })
})

describe("nextSyncTimestamp", () => {
  it("uses the wall clock when it is ahead of everything seen", () => {
    expect(nextSyncTimestamp("dev", undefined, 100)).toEqual(ts(100, 0, "dev"))
    expect(nextSyncTimestamp("dev", ts(50, 3), 100)).toEqual(ts(100, 0, "dev"))
  })

  it("ticks the counter when the clock has not advanced (or is skewed)", () => {
    expect(nextSyncTimestamp("dev", ts(100, 0), 100)).toEqual(ts(100, 1, "dev"))
    expect(nextSyncTimestamp("dev", ts(200, 5), 100)).toEqual(ts(200, 6, "dev"))
  })
})

describe("latestSyncTimestamp", () => {
  it("finds the newest stamp, and is undefined for empty input", () => {
    expect(latestSyncTimestamp([])).toBeUndefined()
    const newest = ts(3, 0, "z")
    expect(
      latestSyncTimestamp([entry("a", 1, ts(2)), entry("b", 2, newest), entry("c", 3, ts(1))])
    ).toEqual(newest)
  })
})

describe("mergeSyncEntries", () => {
  it("keeps newer local entries and adopts newer incoming ones", () => {
    const local = [entry("channel", "stable", ts(5)), entry("theme", "dark", ts(9))]
    const incoming = [entry("channel", "alpha", ts(7)), entry("theme", "light", ts(3))]
    const result = mergeSyncEntries(local, incoming)
    expect(result.merged).toEqual([entry("channel", "alpha", ts(7)), entry("theme", "dark", ts(9))])
    expect(result.changed).toEqual([entry("channel", "alpha", ts(7))])
  })

  it("introduces unseen keys, including tombstones", () => {
    const dead: SyncEntryRecord = { key: "old", value: null, deleted: true, timestamp: ts(4) }
    const result = mergeSyncEntries([], [dead])
    expect(result.merged).toEqual([dead])
    expect(result.changed).toEqual([dead])
  })

  it("is idempotent: merging the same entries again changes nothing", () => {
    const incoming = [entry("a", 1, ts(1)), entry("b", 2, ts(2))]
    const once = mergeSyncEntries([], incoming)
    const twice = mergeSyncEntries(once.merged, incoming)
    expect(twice.merged).toEqual(once.merged)
    expect(twice.changed).toEqual([])
  })

  it("converges regardless of merge order", () => {
    const a = [entry("k", "from-a", ts(10, 0, "a"))]
    const b = [entry("k", "from-b", ts(10, 0, "b"))]
    const ab = mergeSyncEntries(a, b).merged
    const ba = mergeSyncEntries(b, a).merged
    expect(ab).toEqual(ba)
    // Device id breaks the tie deterministically: "b" > "a".
    expect(ab).toEqual([entry("k", "from-b", ts(10, 0, "b"))])
  })

  it("sorts merged output by key", () => {
    const result = mergeSyncEntries(
      [entry("b", 2, ts(1))],
      [entry("a", 1, ts(1)), entry("c", 3, ts(1))]
    )
    expect(result.merged.map((item) => item.key)).toEqual(["a", "b", "c"])
  })
})

describe("isValidSyncNamespace", () => {
  it("accepts boring lowercase names and rejects everything else", () => {
    expect(isValidSyncNamespace("settings")).toBe(true)
    expect(isValidSyncNamespace("harness-accounts")).toBe(true)
    expect(isValidSyncNamespace("")).toBe(false)
    expect(isValidSyncNamespace("1settings")).toBe(false)
    expect(isValidSyncNamespace("Settings")).toBe(false)
    expect(isValidSyncNamespace("a/b")).toBe(false)
    expect(isValidSyncNamespace("a".repeat(65))).toBe(false)
  })
})
