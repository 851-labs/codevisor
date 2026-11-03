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

  func cut(_ source: CVPixelBuffer, tile: Int) throws -> CVPixelBuffer {
    guard layout.count > 1 else { return source }
    guard CVPixelBufferGetWidth(source) == layout.width, CVPixelBufferGetHeight(source) == layout.height else {
      throw ScreenSharingError.invalid("The capture doesn't match the tile layout.")
    }

    let rows = layout.rows(of: tile)
    let target = try make(CVPixelBufferGetPixelFormatType(source), height: rows.count)
    CVBufferPropagateAttachments(source, target)
    if blitter?.copy(rows: rows, of: layout.height, from: source, to: target) == true { return target }

    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(target, [])
    defer {
      CVPixelBufferUnlockBaseAddress(target, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    for plane in ScreenSharingV2PixelPlane.planes(of: source) {
      copy(plane, rows: rows, from: source, to: target)
    }
    return target
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
