import CoreVideo
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

struct ScreenSharingV2TileComparerTests {
  private static let layout = ScreenSharingV2TileLayout(width: 640, height: 360, count: 4)
  private static let limit = 64
  private static let secondTile = 96..<192

  @Test func aTileWhoseChangedPixelsFitTheLimitIsASmallChangeAndUntouchedTilesAreNotChanged() throws {
    let (before, after) = try Self.pair()
    Self.paint(after, rows: 100..<108, columns: 20..<28)

    #expect(Self.compare(before, after) == ScreenSharingV2TileChanges(changed: [1], small: [1]))
  }

  @Test func oneChangedPixelPastTheLimitMakesTheTileALargeChange() throws {
    let (before, after) = try Self.pair()
    Self.paint(after, rows: 100..<108, columns: 20..<28)
    Self.paint(after, rows: 150..<151, columns: 600..<601)

    #expect(Self.compare(before, after) == ScreenSharingV2TileChanges(changed: [1], small: []))
  }

  @Test func aRowCountsEveryPixelFromItsFirstChangedPixelToItsLast() throws {
    let (before, after) = try Self.pair()
    Self.paint(after, rows: 100..<101, columns: 0..<1)
    Self.paint(after, rows: 100..<101, columns: 100..<101)

    #expect(Self.compare(before, after, limit: 100).small.isEmpty)
    #expect(Self.compare(before, after, limit: 101).small == [1])
  }

  @Test func aChangeAtEitherEndOfARowIsMeasuredInPixels() throws {
    let (before, after) = try Self.pair()
    Self.paint(after, rows: 191..<192, columns: 0..<3)
    Self.paint(after, rows: 96..<97, columns: 637..<640)

    #expect(Self.compare(before, after, limit: 5).small.isEmpty)
    #expect(Self.compare(before, after, limit: 6) == ScreenSharingV2TileChanges(changed: [1], small: [1]))
  }

  @Test func onlyTheTilesItIsAskedToMeasureCanBeSmall() throws {
    let (before, after) = try Self.pair()
    Self.paint(after, rows: 100..<101, columns: 20..<21)
    Self.paint(after, rows: 300..<301, columns: 20..<21)

    #expect(Self.compare(before, after, among: [3]) == ScreenSharingV2TileChanges(changed: [1, 3], small: [3]))
  }

  @Test func aLimitOfZeroCallsNoChangeSmall() throws {
    let (before, after) = try Self.pair()
    Self.paint(after, rows: 100..<101, columns: 20..<21)

    #expect(Self.compare(before, after, limit: 0) == ScreenSharingV2TileChanges(changed: [1], small: []))
  }

  @Test func withNoEarlierCaptureEveryTileIsALargeChange() throws {
    let (_, after) = try Self.pair()

    let changes = ScreenSharingV2TileComparer.changes(
      Self.layout.tiles, of: Self.layout, from: nil, to: after, smallUpToPixels: Self.limit, among: Self.layout.tiles)

    #expect(changes == ScreenSharingV2TileChanges(changed: Self.layout.tiles, small: []))
  }

  @Test func eachPlaneOfATwoPlaneCaptureIsHeldToTheLimitOnItsOwnInScreenPixels() throws {
    let before = try TestPixels.frame(shade: 10, timestampNs: 1).pixelBuffer
    let colourOnly = try TestPixels.frame(shade: 10, timestampNs: 2).pixelBuffer
    TestPixels.paint(colourOnly, plane: 1, rows: 50..<54, bytes: 20..<28, value: 200)
    let both = try TestPixels.frame(shade: 10, timestampNs: 3).pixelBuffer
    TestPixels.paint(both, plane: 1, rows: 50..<54, bytes: 20..<28, value: 200)
    TestPixels.paint(both, plane: 0, rows: 100..<108, bytes: 20..<28, value: 200)
    let wideColour = try TestPixels.frame(shade: 10, timestampNs: 4).pixelBuffer
    TestPixels.paint(wideColour, plane: 1, rows: 50..<51, bytes: 20..<60, value: 200)

    #expect(Self.compare(before, colourOnly) == ScreenSharingV2TileChanges(changed: [1], small: [1]))
    #expect(Self.compare(before, both) == ScreenSharingV2TileChanges(changed: [1], small: [1]))
    #expect(Self.compare(before, wideColour) == ScreenSharingV2TileChanges(changed: [1], small: []))
  }

  private static func pair() throws -> (CVPixelBuffer, CVPixelBuffer) {
    (
      try TestBGRAPixels.frame(shades: [10], timestampNs: 1).pixelBuffer,
      try TestBGRAPixels.frame(shades: [10], timestampNs: 2).pixelBuffer
    )
  }

  private static func paint(_ buffer: CVPixelBuffer, rows: Range<Int>, columns: Range<Int>) {
    TestBGRAPixels.paint(buffer, rows: rows, columns: columns) { _, _ in 200 }
  }

  private static func compare(
    _ before: CVPixelBuffer, _ after: CVPixelBuffer, limit: Int = limit, among measured: Set<Int> = layout.tiles
  ) -> ScreenSharingV2TileChanges {
    ScreenSharingV2TileComparer.changes(
      layout.tiles, of: layout, from: before, to: after, smallUpToPixels: limit, among: measured)
  }
}
