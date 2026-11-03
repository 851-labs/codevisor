import Testing

@testable import CodevisorBench

struct HostLabTileSizesTests {
  @Test func countsRefinementPassesFromEachTilesLastChange() {
    var sizes = HostLabTileSizes()
    sizes.record(tile: 0, isRefinement: false, bytes: 9_000)
    sizes.record(tile: 1, isRefinement: false, bytes: 7_000)
    sizes.record(tile: 0, isRefinement: true, bytes: 3_000)
    sizes.record(tile: 0, isRefinement: true, bytes: 200)
    sizes.record(tile: 1, isRefinement: true, bytes: 1_000)
    sizes.record(tile: 0, isRefinement: false, bytes: 8_000)
    sizes.record(tile: 0, isRefinement: true, bytes: 2_000)

    #expect(
      sizes.passes == [
        .init(pass: 0, count: 3, meanBytes: 8_000, p50Bytes: 8_000),
        .init(pass: 1, count: 3, meanBytes: 2_000, p50Bytes: 2_000),
        .init(pass: 2, count: 1, meanBytes: 200, p50Bytes: 200),
      ])
  }
}
