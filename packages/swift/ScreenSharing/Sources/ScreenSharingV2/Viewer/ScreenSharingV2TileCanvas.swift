import CoreVideo
import ScreenSharing

struct ScreenSharingV2TileCanvas: @unchecked Sendable {
  struct Snapshot: @unchecked Sendable {
    let layout: ScreenSharingV2TileLayout
    let images: [Int: CVPixelBuffer]
    let pixelFormat: OSType

    var tiles: [ScreenSharingVideoTile]? {
      guard layout.count > 1, images.count == layout.count,
        images.values.allSatisfy({ CVPixelBufferGetPixelFormatType($0) == pixelFormat })
      else { return nil }

      return layout.tiles.sorted().compactMap { tile in
        images[tile].map { ScreenSharingVideoTile(pixelBuffer: $0, rows: layout.rows(of: tile)) }
      }
    }
  }

  let layout: ScreenSharingV2TileLayout
  private var images: [Int: CVPixelBuffer] = [:]
  private var newestFormat: OSType?

  init(layout: ScreenSharingV2TileLayout) {
    self.layout = layout
  }

  mutating func place(_ image: CVPixelBuffer, tile: Int) {
    images[tile] = image
    newestFormat = CVPixelBufferGetPixelFormatType(image)
  }

  var isComplete: Bool { layout.count > 1 && images.count == layout.count }

  var snapshot: Snapshot? {
    newestFormat.map { Snapshot(layout: layout, images: images, pixelFormat: $0) }
  }
}
