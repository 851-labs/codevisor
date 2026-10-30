import CoreVideo
import Foundation

struct EncodeLabTileCutter: @unchecked Sendable {
  let tiles: Int
  let height: Int
  private let pool: EncodeLabPixelPool

  init(width: Int, height: Int, tiles: Int, format: OSType) throws {
    self.tiles = tiles
    self.height = height
    pool = try EncodeLabPixelPool(width: width, height: height / tiles, format: format)
  }

  func cut(_ source: CVPixelBuffer, tile: Int) throws -> CVPixelBuffer {
    guard tiles > 1 else { return source }

    let target = try pool.make()
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(target, [])
    defer {
      CVPixelBufferUnlockBaseAddress(target, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    for plane in EncodeLabPlaneRows.planes(of: source) {
      copy(plane, tile: tile, from: source, to: target)
    }
    return target
  }

  private func copy(_ plane: EncodeLabPlaneRows, tile: Int, from source: CVPixelBuffer, to target: CVPixelBuffer) {
    let rows = plane.rows(ofTile: tile, tiles: tiles)
    let sourceStride = plane.bytesPerRow(source)
    let targetStride = plane.bytesPerRow(target)
    let length = min(sourceStride, targetStride)
    let sourceBase = plane.base(source)
    let targetBase = plane.base(target)
    for (targetRow, sourceRow) in rows.enumerated() {
      memcpy(targetBase + targetRow * targetStride, sourceBase + sourceRow * sourceStride, length)
    }
  }
}
