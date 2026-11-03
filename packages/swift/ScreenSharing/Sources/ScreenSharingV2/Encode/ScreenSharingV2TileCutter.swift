import CoreVideo
import Foundation
import ScreenSharing

final class ScreenSharingV2TileCutter: @unchecked Sendable {
  private struct PoolKey: Hashable {
    let pixelFormat: OSType
    let height: Int
  }

  let layout: ScreenSharingV2TileLayout
  private let blitter = ScreenSharingV2TileBlitter()
  private let lock = NSLock()
  private var pools: [PoolKey: CVPixelBufferPool] = [:]

  init(layout: ScreenSharingV2TileLayout) {
    self.layout = layout
  }

  func cut(_ source: CVPixelBuffer, tiles: [Int]) throws -> [Int: CVPixelBuffer] {
    guard layout.count > 1 else { return Dictionary(uniqueKeysWithValues: tiles.map { ($0, source) }) }
    guard CVPixelBufferGetWidth(source) == layout.width, CVPixelBufferGetHeight(source) == layout.height else {
      throw ScreenSharingError.invalid("The capture doesn't match the tile layout.")
    }

    let targets = try Dictionary(
      uniqueKeysWithValues: tiles.map { tile in
        let target = try make(CVPixelBufferGetPixelFormatType(source), height: layout.rows(of: tile).count)
        CVBufferPropagateAttachments(source, target)
        return (tile, target)
      })
    let regions = targets.map { tile, target in
      let rows = layout.rows(of: tile)
      return ScreenSharingV2TileBlitter.Copy(
        source: source, target: target, sourceRow: rows.lowerBound, targetRow: 0, rows: rows.count)
    }
    if blitter?.copy(regions) == true { return targets }

    CVPixelBufferLockBaseAddress(source, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    for (tile, target) in targets {
      CVPixelBufferLockBaseAddress(target, [])
      defer { CVPixelBufferUnlockBaseAddress(target, []) }
      for plane in ScreenSharingV2PixelPlane.planes(of: source) {
        copy(plane, rows: layout.rows(of: tile), from: source, to: target)
      }
    }
    return targets
  }

  private func copy(
    _ plane: ScreenSharingV2PixelPlane, rows: Range<Int>, from source: CVPixelBuffer, to target: CVPixelBuffer
  ) {
    guard let sourceBase = plane.base(of: source), let targetBase = plane.base(of: target) else { return }

    let first = rows.lowerBound * plane.height(of: source) / layout.height
    let count = plane.height(of: target)
    let sourceStride = plane.bytesPerRow(of: source)
    let targetStride = plane.bytesPerRow(of: target)
    if sourceStride == targetStride {
      memcpy(targetBase, sourceBase + first * sourceStride, count * sourceStride)
      return
    }
    let length = min(sourceStride, targetStride)
    for row in 0..<count {
      memcpy(targetBase + row * targetStride, sourceBase + (first + row) * sourceStride, length)
    }
  }

  private func make(_ pixelFormat: OSType, height: Int) throws -> CVPixelBuffer {
    let pool = try lock.withLock {
      let key = PoolKey(pixelFormat: pixelFormat, height: height)
      if let pool = pools[key] { return pool }
      let pool = try ScreenSharingV2PixelPool.make(width: layout.width, height: height, pixelFormat: pixelFormat)
      pools[key] = pool
      return pool
    }
    return try ScreenSharingV2PixelPool.buffer(from: pool)
  }
}
