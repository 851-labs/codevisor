import Testing
@testable import CodevisorUI

@Suite("Diff structure cache")
struct DiffStructureCacheTests {
  @Test("Prepared rows are available synchronously after warming")
  @MainActor
  func preparedRowsAreReused() async {
    let cache = DiffStructureCache(limit: 2)
    let key = DiffStructureCache.Key(
      oldText: "    let value = 1\n",
      newText: "    let value = 2\n"
    )

    let prepared = await cache.prepare(key)

    #expect(!prepared.rows.isEmpty)
    #expect(prepared.dedentedOld == "let value = 1\n")
    #expect(prepared.dedentedNew == "let value = 2\n")
    #expect(cache.entry(for: key) == prepared)
  }
}
