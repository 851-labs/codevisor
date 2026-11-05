import CoreVideo
import Foundation
import ScreenSharing
import VideoToolbox

final class ScreenSharingV2FrameComposer: @unchecked Sendable {
  private struct PoolKey: Equatable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
  }

  private struct Staged {
    let key: PoolKey
    let target: CVPixelBuffer
    var tiles: [Int: CVPixelBuffer] = [:]
  }

  private static let fullRangeFormats: Set<OSType> = [
    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
  ]

  private let lock = NSLock()
  private let blitter = ScreenSharingV2TileBlitter()
  private var pool: (key: PoolKey, pool: CVPixelBufferPool)?
  private var transfer: VTPixelTransferSession?
  private var staged: Staged?

  deinit {
    if let transfer { VTPixelTransferSessionInvalidate(transfer) }
  }

  func stage(_ image: CVPixelBuffer, tile: Int, layout: ScreenSharingV2TileLayout) {
    guard layout.count > 1 else { return }

    lock.withLock {
      let key = PoolKey(
        width: layout.width, height: layout.height, pixelFormat: CVPixelBufferGetPixelFormatType(image))
      if staged?.key != key { staged = (try? make(key)).map { Staged(key: key, target: $0) } }
      guard let target = staged?.target, blit([(tile, image)], into: target, layout: layout) else { return }

      staged?.tiles[tile] = image
    }
  }

  func compose(_ snapshot: ScreenSharingV2TileCanvas.Snapshot) throws -> CVPixelBuffer? {
    let layout = snapshot.layout
    if layout.count == 1 { return snapshot.images[0] }

    return try lock.withLock {
      let key = PoolKey(width: layout.width, height: layout.height, pixelFormat: snapshot.pixelFormat)
      let reused = staged.flatMap { $0.key == key ? $0 : nil }
      staged = nil
      let target = try reused?.target ?? make(key)
      let pending = layout.tiles.sorted().filter { tile in
        guard let placed = reused?.tiles[tile], let image = snapshot.images[tile] else { return true }

        return placed !== image
      }
      let sources = try pending.map { tile in
        try snapshot.images[tile].map { try converted($0, to: snapshot.pixelFormat) }
      }
      let placed = Array(zip(pending, sources))
      if placed.contains(where: { $0.1 == nil }) || !blit(placed, into: target, layout: layout) {
        CVPixelBufferLockBaseAddress(target, [])
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        for (tile, image) in placed {
          if let image {
            copy(image, into: target, rows: layout.rows(of: tile), height: layout.height)
          } else {
            blank(target, rows: layout.rows(of: tile), height: layout.height)
          }
        }
      }
      if let first = layout.tiles.sorted().lazy.compactMap({ snapshot.images[$0] }).first {
        CVBufferPropagateAttachments(first, target)
      }
      return target
    }
  }

  private func blit(
    _ placed: [(Int, CVPixelBuffer?)], into target: CVPixelBuffer, layout: ScreenSharingV2TileLayout
  ) -> Bool {
    guard !placed.isEmpty else { return true }

    let regions = placed.compactMap { tile, image in
      image.map { image in
        ScreenSharingV2TileBlitter.Copy(
          source: image, target: target, sourceRow: 0, targetRow: layout.rows(of: tile).lowerBound,
          rows: min(layout.rows(of: tile).count, CVPixelBufferGetHeight(image)))
      }
    }
    return blitter?.copy(regions) == true
  }

  private func copy(_ image: CVPixelBuffer, into target: CVPixelBuffer, rows: Range<Int>, height: Int) {
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    for plane in ScreenSharingV2PixelPlane.planes(of: target) {
      let span = plane.rows(rows, of: target, height: height)
      plane.copyRows(span.count, from: image, at: 0, to: target, at: span.lowerBound)
    }
  }

  private func blank(_ target: CVPixelBuffer, rows: Range<Int>, height: Int) {
    for plane in ScreenSharingV2PixelPlane.planes(of: target) {
      guard let destination = plane.base(of: target) else { continue }

      let span = plane.rows(rows, of: target, height: height)
      let stride = plane.bytesPerRow(of: target)
      let black: Int32 = Self.fullRangeFormats.contains(CVPixelBufferGetPixelFormatType(target)) ? 0 : 16
      memset(destination + span.lowerBound * stride, plane.index == 0 ? black : 128, span.count * stride)
    }
  }

  private func converted(_ image: CVPixelBuffer, to pixelFormat: OSType) throws -> CVPixelBuffer {
    guard CVPixelBufferGetPixelFormatType(image) != pixelFormat else { return image }

    var created: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()] as CFDictionary
    let status = CVPixelBufferCreate(
      nil, CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image), pixelFormat, attributes, &created)
    guard status == kCVReturnSuccess, let created else { throw ScreenSharingError.codec("Allocate tile", status) }

    try Self.check(VTPixelTransferSessionTransferImage(try session(), from: image, to: created))
    return created
  }

  private func session() throws -> VTPixelTransferSession {
    if let transfer { return transfer }
    var created: VTPixelTransferSession?
    try Self.check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created))
    guard let created else { throw ScreenSharingError.unavailable("No pixel transfer session.") }

    transfer = created
    return created
  }

  private func make(_ key: PoolKey) throws -> CVPixelBuffer {
    if pool?.key != key {
      pool = (
        key, try ScreenSharingV2PixelPool.make(width: key.width, height: key.height, pixelFormat: key.pixelFormat)
      )
    }
    return try ScreenSharingV2PixelPool.buffer(from: pool!.pool)
  }

  private static func check(_ status: OSStatus) throws {
    guard status == noErr else { throw ScreenSharingError.codec("Convert tile", status) }
  }
}
