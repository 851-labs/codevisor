import CoreVideo
import Foundation
import Synchronization

enum ScreenSharingV2TileComparer {
  private enum Extent {
    case unchanged
    case small
    case large
  }

  static func changes(
    _ tiles: Set<Int>, of layout: ScreenSharingV2TileLayout, from previous: CVPixelBuffer?, to current: CVPixelBuffer,
    smallUpToPixels limit: Int, among measured: Set<Int>
  ) -> ScreenSharingV2TileChanges {
    guard let previous, previous !== current, comparable(previous, current, layout: layout) else {
      return ScreenSharingV2TileChanges(changed: tiles)
    }

    CVPixelBufferLockBaseAddress(previous, .readOnly)
    CVPixelBufferLockBaseAddress(current, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(current, .readOnly)
      CVPixelBufferUnlockBaseAddress(previous, .readOnly)
    }
    let planes = ScreenSharingV2PixelPlane.planes(of: current)
    nonisolated(unsafe) let extent = { (tile: Int) in
      Self.extent(
        planes, rows: layout.rows(of: tile), height: layout.height, previous, current,
        limit: measured.contains(tile) ? limit : 0)
    }
    let candidates = Array(tiles)
    let changes = Mutex(ScreenSharingV2TileChanges())
    DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
      let tile = candidates[index]
      let measured = extent(tile)
      guard measured != .unchanged else { return }

      changes.withLock { changes in
        changes.changed.insert(tile)
        if measured == .small { changes.small.insert(tile) }
      }
    }
    return changes.withLock { $0 }
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

  private static func extent(
    _ planes: [ScreenSharingV2PixelPlane], rows: Range<Int>, height: Int, _ previous: CVPixelBuffer,
    _ current: CVPixelBuffer, limit: Int
  ) -> Extent {
    var changed = false
    for plane in planes {
      guard let pixels = changedPixels(plane, rows: rows, height: height, previous, current, upTo: limit) else {
        return .large
      }

      changed = changed || pixels > 0
    }
    return changed ? .small : .unchanged
  }

  private static func changedPixels(
    _ plane: ScreenSharingV2PixelPlane, rows: Range<Int>, height: Int, _ previous: CVPixelBuffer,
    _ current: CVPixelBuffer, upTo limit: Int
  ) -> Int? {
    guard let old = plane.base(of: previous), let new = plane.base(of: current) else { return nil }

    let oldStride = plane.bytesPerRow(of: previous)
    let newStride = plane.bytesPerRow(of: current)
    let bytesPerPixel = pixelBytes(plane)
    let length = min(oldStride, newStride, rowBytes(plane, of: current))
    var pixels = 0
    for row in plane.rows(rows, of: current, height: height) {
      pixels += changedSpan(old + row * oldStride, new + row * newStride, length: length, pixelBytes: bytesPerPixel)
      if pixels > limit { return nil }
    }
    return pixels
  }

  private static func changedSpan(
    _ old: UnsafeRawPointer, _ new: UnsafeRawPointer, length: Int, pixelBytes: Int
  ) -> Int {
    guard memcmp(old, new, length) != 0 else { return 0 }

    let word = MemoryLayout<UInt64>.size
    var first = 0
    while first + word <= length, same(old, new, at: first, as: UInt64.self) { first += word }
    while same(old, new, at: first, as: UInt8.self) { first += 1 }
    var end = length
    while end - word >= first, same(old, new, at: end - word, as: UInt64.self) { end -= word }
    while same(old, new, at: end - 1, as: UInt8.self) { end -= 1 }
    return (end - 1) / pixelBytes - first / pixelBytes + 1
  }

  private static func same<Value: FixedWidthInteger>(
    _ old: UnsafeRawPointer, _ new: UnsafeRawPointer, at offset: Int, as type: Value.Type
  ) -> Bool {
    old.loadUnaligned(fromByteOffset: offset, as: type) == new.loadUnaligned(fromByteOffset: offset, as: type)
  }

  private static func pixelBytes(_ plane: ScreenSharingV2PixelPlane) -> Int {
    guard let index = plane.index else { return 4 }

    return index == 0 ? 1 : 2
  }

  private static func rowBytes(_ plane: ScreenSharingV2PixelPlane, of buffer: CVPixelBuffer) -> Int {
    guard let index = plane.index else { return CVPixelBufferGetWidth(buffer) * 4 }

    return CVPixelBufferGetWidthOfPlane(buffer, index) * (index == 0 ? 1 : 2)
  }
}
