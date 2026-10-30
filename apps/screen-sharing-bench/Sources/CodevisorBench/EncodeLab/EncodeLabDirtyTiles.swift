import CoreVideo
import Foundation

enum EncodeLabDirtyTiles {
  static func changed(from previous: CVPixelBuffer?, to current: CVPixelBuffer, tiles: Int) -> Set<Int> {
    guard let previous else { return Set(0..<tiles) }

    CVPixelBufferLockBaseAddress(previous, .readOnly)
    CVPixelBufferLockBaseAddress(current, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(current, .readOnly)
      CVPixelBufferUnlockBaseAddress(previous, .readOnly)
    }
    let plane = EncodeLabPlaneRows(index: nil, height: CVPixelBufferGetHeight(current))
    return Set((0..<tiles).filter { differs(plane.rows(ofTile: $0, tiles: tiles), previous, current) })
  }

  private static func differs(_ rows: Range<Int>, _ previous: CVPixelBuffer, _ current: CVPixelBuffer) -> Bool {
    let stride = CVPixelBufferGetBytesPerRow(current)
    let length = CVPixelBufferGetWidth(current) * 4
    guard let old = CVPixelBufferGetBaseAddress(previous), let new = CVPixelBufferGetBaseAddress(current) else {
      return true
    }

    return rows.contains { memcmp(old + $0 * stride, new + $0 * stride, length) != 0 }
  }
}
