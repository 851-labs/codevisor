import CoreGraphics
import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2TileLayoutTests {
  @Test(arguments: [
    (2160, [544, 544, 544, 528]), (1964, [496, 496, 496, 476]), (1080, [272, 272, 272, 264]), (192, [64, 64, 64]),
  ])
  func tilesAreSixteenRowStripesThatCoverEveryRowOnce(height: Int, rows: [Int]) {
    let layout = ScreenSharingV2TileLayout(width: 3840, height: height, count: 4)

    #expect(layout.tiles.sorted().map { layout.rows(of: $0).count } == rows)
    #expect(layout.tiles.sorted().map { layout.rows(of: $0).lowerBound } == rows.indices.map { $0 * rows[0] })
  }

  @Test func anEncoderCanDescribeItsOwnTileHeight() {
    let layout = ScreenSharingV2TileLayout(width: 3840, height: 2160, count: 4, tileHeight: 576)

    #expect(layout.tiles.sorted().map { layout.rows(of: $0) } == [0..<576, 576..<1152, 1152..<1728, 1728..<2160])
  }

  @Test func dirtyRectsMarkEveryTileTheyTouchAndNoOther() {
    let layout = ScreenSharingV2TileLayout(width: 3840, height: 2160, count: 4)

    #expect(layout.tiles(touching: nil) == [0, 1, 2, 3])
    #expect(layout.tiles(touching: []).isEmpty)
    #expect(layout.tiles(touching: [CGRect(x: 10, y: 0, width: 5, height: 544)]) == [0])
    #expect(layout.tiles(touching: [CGRect(x: 10, y: 543.5, width: 5, height: 1)]) == [0, 1])
    #expect(layout.tiles(touching: [CGRect(x: 0, y: 2000, width: 9000, height: 900)]) == [3])
    #expect(layout.tiles(touching: [CGRect(x: 4000, y: 0, width: 5, height: 5), .zero]).isEmpty)
  }
}
