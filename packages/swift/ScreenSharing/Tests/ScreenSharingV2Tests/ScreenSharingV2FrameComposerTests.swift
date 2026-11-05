import CoreVideo
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

struct ScreenSharingV2FrameComposerTests {
  private static let layout = ScreenSharingV2TileLayout(width: 64, height: 256, count: 4)

  @Test func tilesStagedAsTheyDecodeComposeTheSamePictureAsComposingThemAllAtOnce() throws {
    let images = try [10, 60, 110, 160].map { try Self.tile(shade: $0) }
    let snapshot = Self.snapshot(images)
    let staging = ScreenSharingV2FrameComposer()
    for tile in 0..<3 { staging.stage(images[tile], tile: tile, layout: Self.layout) }

    let staged = try #require(try staging.compose(snapshot))
    let whole = try #require(try ScreenSharingV2FrameComposer().compose(snapshot))

    #expect(Self.shades(of: staged) == [10, 60, 110, 160])
    #expect(Self.shades(of: staged) == Self.shades(of: whole))
  }

  @Test func aStagedTileThatIsNoLongerTheCanvasesImageIsComposedFromTheCanvas() throws {
    let composer = ScreenSharingV2FrameComposer()
    composer.stage(try Self.tile(shade: 200), tile: 1, layout: Self.layout)

    let composed = try #require(
      try composer.compose(Self.snapshot(try [10, 60, 110, 160].map { try Self.tile(shade: $0) })))

    #expect(Self.shades(of: composed) == [10, 60, 110, 160])
  }

  private static func snapshot(_ images: [CVPixelBuffer]) -> ScreenSharingV2TileCanvas.Snapshot {
    ScreenSharingV2TileCanvas.Snapshot(
      layout: layout, images: Dictionary(uniqueKeysWithValues: images.enumerated().map { ($0, $1) }),
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
  }

  private static func tile(shade: Int) throws -> CVPixelBuffer {
    try TestPixels.frame(width: layout.width, height: layout.tileHeight, shade: UInt8(shade), timestampNs: 0)
      .pixelBuffer
  }

  private static func shades(of picture: CVPixelBuffer) -> [Int] {
    layout.tiles.sorted().map { Int(TestPixels.luma(of: picture, row: layout.rows(of: $0).lowerBound + 3, column: 5)) }
  }
}
