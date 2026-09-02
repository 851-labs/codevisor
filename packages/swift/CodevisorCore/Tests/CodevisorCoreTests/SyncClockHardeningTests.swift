import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

/// Phase 15: ownership-model hardening for the Swift half of the LWW core.
/// SyncClock mirrors @codevisor/sync and both sides MUST merge identically;
/// the "conformance vector" here is duplicated verbatim from
/// packages/sync/src/hardening.test.ts — if either suite's expectation
/// changes, the other must change with it or replicas diverge.
@Suite("SyncClockHardening")
struct SyncClockHardeningTests {
  private func ts(_ wallMs: Int, _ counter: Int, _ deviceId: String) -> ServerSyncTimestamp {
    ServerSyncTimestamp(wallMs: wallMs, counter: counter, deviceId: deviceId)
  }

  private func entry(
    _ key: String, _ value: JSONValue, _ timestamp: ServerSyncTimestamp
  )
    -> ServerSyncEntry
  {
    ServerSyncEntry(key: key, value: value, timestamp: timestamp)
  }

  private func dead(_ key: String, _ timestamp: ServerSyncTimestamp) -> ServerSyncEntry {
    ServerSyncEntry(key: key, value: .null, deleted: true, timestamp: timestamp)
  }

  /// The shared conformance vector: every tiebreak rung (wall clock,
  /// counter, device id), a tombstone, and a deliberate revival.
  private var batchAlpha: [ServerSyncEntry] {
    [
      entry("theme", .string("dark"), ts(100, 0, "alpha")),
      entry("font", .string("mono"), ts(120, 0, "alpha")),
      dead("channel", ts(140, 0, "alpha")),
    ]
  }

  private var batchBeta: [ServerSyncEntry] {
    [
      entry("theme", .string("light"), ts(100, 0, "beta")),
      entry("channel", .string("alpha-build"), ts(130, 0, "beta")),
      entry("scale", .number(2), ts(90, 0, "beta")),
    ]
  }

  private var batchGamma: [ServerSyncEntry] {
    [
      entry("font", .string("serif"), ts(120, 1, "gamma")),
      entry("scale", .number(3), ts(90, 0, "gamma")),
      entry("channel", .string("beta-build"), ts(150, 0, "gamma")),
    ]
  }

  private var expectedConvergence: [ServerSyncEntry] {
    [
      entry("channel", .string("beta-build"), ts(150, 0, "gamma")),
      entry("font", .string("serif"), ts(120, 1, "gamma")),
      entry("scale", .number(3), ts(90, 0, "gamma")),
      entry("theme", .string("light"), ts(100, 0, "beta")),
    ]
  }

  private func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    var result: [[T]] = []
    for index in items.indices {
      var rest = items
      let head = rest.remove(at: index)
      for tail in permutations(rest) {
        result.append([head] + tail)
      }
    }
    return result
  }

  @Test("The conformance vector converges in every gossip order")
  func conformanceVectorConverges() {
    for order in permutations([batchAlpha, batchBeta, batchGamma]) {
      var document: [ServerSyncEntry] = []
      for batch in order {
        document = SyncClock.merge(document, batch).merged
      }
      #expect(document == expectedConvergence)
    }
  }

  @Test("Relaying only the changed set still converges a fresh replica")
  func changedRelayConverges() {
    var document: [ServerSyncEntry] = []
    var relayed: [ServerSyncEntry] = []
    for batch in [batchAlpha, batchBeta, batchGamma] {
      let result = SyncClock.merge(document, batch)
      document = result.merged
      relayed.append(contentsOf: result.changed)
    }
    #expect(SyncClock.merge([], relayed).merged == expectedConvergence)
  }

  @Test("A device hours behind still wins its causally-later edits")
  func skewedDeviceWinsCausallyLaterEdits() {
    let remote = entry("k", .string("fleet"), ts(1_000_000, 0, "fast"))
    var document = SyncClock.merge([], [remote]).merged
    // Wall clock reads 500, but the ratchet stamps past everything seen.
    let stamp = SyncClock.next(after: SyncClock.latest(in: document), deviceId: "slow", nowMs: 500)
    #expect(stamp == ts(1_000_000, 1, "slow"))
    let local = entry("k", .string("local"), stamp)
    document = SyncClock.merge(document, [local]).merged
    #expect(document == [local])
    // The fleet adopts it too — the skewed device is not second-class.
    #expect(SyncClock.merge([remote], [local]).changed == [local])
  }

  @Test("Stale writes never resurrect a tombstone; a later re-add does")
  func tombstoneResurrection() {
    let tombstone = dead("mcp", ts(100, 0, "deleter"))
    // A stale live value and a replay of pre-delete history are inert.
    let stale = SyncClock.merge([tombstone], [entry("mcp", .string("zombie"), ts(90, 0, "stale"))])
    #expect(stale.changed.isEmpty)
    #expect(stale.merged == [tombstone])
    let replay = SyncClock.merge(
      [tombstone],
      [
        entry("mcp", .string("v1"), ts(50, 0, "author")),
        entry("mcp", .string("v2"), ts(80, 2, "author")),
      ]
    )
    #expect(replay.changed.isEmpty)
    #expect(replay.merged == [tombstone])
    // Dueling tombstones resolve deterministically like any write.
    let rival = dead("mcp", ts(100, 0, "zeta"))
    #expect(SyncClock.merge([tombstone], [rival]).merged == [rival])
    #expect(SyncClock.merge([rival], [tombstone]).merged == [rival])
    // A deliberate causally-later re-add revives the key — by design.
    let stamp = SyncClock.next(after: SyncClock.latest(in: [tombstone]), deviceId: "author", nowMs: 100)
    let revived = entry("mcp", .string("reborn"), stamp)
    #expect(SyncClock.merge([tombstone], [revived]).merged == [revived])
    #expect(SyncClock.merge([revived], [tombstone]).merged == [revived])
  }

  @Test("Counters disambiguate a burst of writes inside one millisecond")
  func burstCounters() {
    var clock: ServerSyncTimestamp?
    var burst: [ServerSyncEntry] = []
    for value in ["a", "b", "c"] {
      clock = SyncClock.next(after: clock, deviceId: "dev", nowMs: 777)
      burst.append(entry("k", .string(value), clock!))
    }
    #expect(burst.map(\.timestamp.counter) == [0, 1, 2])
    // Merged in any order, the last write of the burst wins.
    #expect(SyncClock.merge([], burst.reversed()).merged == [burst[2]])
    #expect(SyncClock.merge([], burst).merged == [burst[2]])
  }
}
