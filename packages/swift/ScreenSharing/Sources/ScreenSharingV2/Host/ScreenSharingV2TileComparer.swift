import CoreVideo
import Foundation
import Synchronization

enum ScreenSharingV2TileComparer {
  static func changed(
    _ tiles: Set<Int>, of layout: ScreenSharingV2TileLayout, from previous: CVPixelBuffer?, to current: CVPixelBuffer
  ) -> Set<Int> {
    guard let previous, previous !== current, comparable(previous, current, layout: layout) else { return tiles }

    CVPixelBufferLockBaseAddress(previous, .readOnly)
    CVPixelBufferLockBaseAddress(current, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(current, .readOnly)
      CVPixelBufferUnlockBaseAddress(previous, .readOnly)
    }
    let planes = ScreenSharingV2PixelPlane.planes(of: current)
    nonisolated(unsafe) let tileDiffers = { (tile: Int) in
      planes.contains { differs($0, rows: layout.rows(of: tile), height: layout.height, previous, current) }
    }
    guard tiles.count > 1 else { return tiles.filter(tileDiffers) }

    let candidates = Array(tiles)
    let changed = Mutex(Set<Int>())
    DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
      guard tileDiffers(candidates[index]) else { return }

      changed.withLock { _ = $0.insert(candidates[index]) }
    }
    return changed.withLock { $0 }
  }

  private static func comparable(
    _ previous: CVPixelBuffer, _ current: CVPixelBuffer, layout: ScreenSharingV2TileLayout
  )
    -> Bool
  {
    CVPixelBufferGetPixelFormatType(previous) == CVPixelBufferGetPixelFormatType(current)
      && CVPixelBufferGetWidth(previous) == layout.width && CVPixelBufferGetHeight(previous) == layout.height
      && CVPixelBufferGetWidth(current) == layout.width && CVPixelBufferGetHeight(current) == layout.height
  }

  private static func differs(
    _ plane: ScreenSharingV2PixelPlane, rows: Range<Int>, height: Int, _ previous: CVPixelBuffer,
    _ current: CVPixelBuffer
  ) -> Bool {
    guard let old = plane.base(of: previous), let new = plane.base(of: current) else { return true }

    let oldStride = plane.bytesPerRow(of: previous)
    let newStride = plane.bytesPerRow(of: current)
    let length = min(oldStride, newStride, rowBytes(plane, of: current))
    return plane.rows(rows, of: current, height: height).contains { row in
      memcmp(old + row * oldStride, new + row * newStride, length) != 0
    }
  }

  private static func rowBytes(_ plane: ScreenSharingV2PixelPlane, of buffer: CVPixelBuffer) -> Int {
    guard let index = plane.index else { return CVPixelBufferGetWidth(buffer) * 4 }

    return CVPixelBufferGetWidthOfPlane(buffer, index) * (index == 0 ? 1 : 2)
  }
}
