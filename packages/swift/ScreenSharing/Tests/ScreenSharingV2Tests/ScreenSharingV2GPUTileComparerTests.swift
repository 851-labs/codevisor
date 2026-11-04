import CoreVideo
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

struct ScreenSharingV2GPUTileComparerTests {
  private static let layout = ScreenSharingV2TileLayout(width: 640, height: 360, count: 4)

  @Test func lumaAndChromaChangesMarkOnlyTheTilesTheyFallIn() throws {
    let comparer = try #require(ScreenSharingV2GPUTileComparer())
    let previous = try Self.frame()
    let lumaInTile2 = try Self.frame(plane: 0, row: Self.layout.rows(of: 2).lowerBound + 3)
    let chromaInTile1 = try Self.frame(plane: 1, row: Self.layout.rows(of: 1).lowerBound / 2 + 1)

    #expect(comparer.changed(Self.layout.tiles, of: Self.layout, from: previous, to: try Self.frame()) == [])
    #expect(comparer.changed(Self.layout.tiles, of: Self.layout, from: previous, to: lumaInTile2) == [2])
    #expect(comparer.changed(Self.layout.tiles, of: Self.layout, from: previous, to: chromaInTile1) == [1])
    #expect(comparer.changed([0, 1], of: Self.layout, from: previous, to: lumaInTile2) == [])
  }

  private static func frame(plane: Int? = nil, row: Int = 0) throws -> CVPixelBuffer {
    let buffer = try TestPixels.frame(shade: 10, timestampNs: 0).pixelBuffer
    guard let plane else { return buffer }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)).assumingMemoryBound(to: UInt8.self)
    base[row * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) + 5] &+= 40
    return buffer
  }
}
