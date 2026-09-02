import Foundation
import Testing

@testable import CodevisorCore

struct SessionMeasurementCacheStoreTests {
  @Test
  func activatingKeysEvictsLeastRecentlyUsedCache() {
    var store = SessionMeasurementCacheStore(maximumCacheCount: 2)
    let first = key(width: 100)
    let second = key(width: 200)
    let third = key(width: 300)

    store.activate(first)
    store.store(measurement(height: 10), for: "first")
    store.activate(second)
    store.store(measurement(height: 20), for: "second")
    store.activate(first)
    store.activate(third)

    #expect(store.caches[first]?["first"]?.height == 10)
    #expect(store.caches[second] == nil)
    #expect(store.activeKey == third)
    #expect(store.lru == [first, third])
  }

  @Test
  func rowMutationKeepsActiveCacheAndSettledSnapshotAligned() {
    var store = SessionMeasurementCacheStore()
    let cacheKey = key(width: 100)
    let row = measurement(height: 42)

    store.activate(cacheKey)
    store.store(row, for: "row")

    #expect(store.settledRows["row"] == row)
    #expect(store.caches[cacheKey]?["row"] == row)

    store.removeMeasurement(for: "row")

    #expect(store.settledRows["row"] == nil)
    #expect(store.caches[cacheKey]?["row"] == nil)
  }

  @Test
  func restoreFiltersUnknownRecencyKeysAndClearsActiveSnapshot() {
    var store = SessionMeasurementCacheStore()
    let retained = key(width: 100)
    let missing = key(width: 200)
    let row = measurement(height: 30)

    store.restore(
      caches: [retained: ["row": row]],
      lru: [missing, retained]
    )

    #expect(store.lru == [retained])
    #expect(store.activeKey == nil)
    #expect(store.settledRows.isEmpty)
    #expect(store.activate(retained)["row"] == row)
  }

  private func key(width: Int) -> SessionMeasurementCacheKey {
    SessionMeasurementCacheKey(
      rowWidthHalfPoints: width,
      layoutFingerprint: 1
    )
  }

  private func measurement(height: CGFloat) -> SessionMeasuredRow {
    SessionMeasuredRow(height: height, revision: 1)
  }
}
