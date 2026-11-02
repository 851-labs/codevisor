import CoreVideo
import ScreenSharing

struct ScreenSharingV2TileCanvas: @unchecked Sendable {
  let layout: ScreenSharingV2TileLayout
  private var images: [Int: CVPixelBuffer] = [:]
  private var pool: (pixelFormat: OSType, pool: CVPixelBufferPool)?

  init(layout: ScreenSharingV2TileLayout) {
    self.layout = layout
  }

  mutating func place(_ image: CVPixelBuffer, tile: Int) {
    images[tile] = image
  }

  mutating func compose() throws -> CVPixelBuffer? {
    if layout.count == 1 { return images[0] }
    guard !images.isEmpty else { return nil }

    guard let pixelFormat = images.values.first.map(CVPixelBufferGetPixelFormatType) else { return nil }

    let target = try make(pixelFormat)
    CVPixelBufferLockBaseAddress(target, [])
    defer { CVPixelBufferUnlockBaseAddress(target, []) }
    for tile in layout.tiles.sorted() {
      if let image = images[tile] {
        copy(image, into: target, rows: layout.rows(of: tile))
      } else {
        blank(target, rows: layout.rows(of: tile))
      }
    }
    if let first = images.values.first { CVBufferPropagateAttachments(first, target) }
    return target
  }

  private func copy(_ image: CVPixelBuffer, into target: CVPixelBuffer, rows: Range<Int>) {
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let planes = min(CVPixelBufferGetPlaneCount(image), CVPixelBufferGetPlaneCount(target))
    for plane in 0..<planes {
      guard let source = CVPixelBufferGetBaseAddressOfPlane(image, plane),
        let destination = CVPixelBufferGetBaseAddressOfPlane(target, plane)
      else { continue }

      let span = planeRows(rows, plane: plane, of: target)
      let count = min(span.count, CVPixelBufferGetHeightOfPlane(image, plane))
      let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
      let targetStride = CVPixelBufferGetBytesPerRowOfPlane(target, plane)
      let length = min(sourceStride, targetStride)
      for row in 0..<count {
        memcpy(destination + (span.lowerBound + row) * targetStride, source + row * sourceStride, length)
      }
    }
  }

  private func blank(_ target: CVPixelBuffer, rows: Range<Int>) {
    for plane in 0..<CVPixelBufferGetPlaneCount(target) {
      guard let destination = CVPixelBufferGetBaseAddressOfPlane(target, plane) else { continue }

      let span = planeRows(rows, plane: plane, of: target)
      let stride = CVPixelBufferGetBytesPerRowOfPlane(target, plane)
      memset(destination + span.lowerBound * stride, plane == 0 ? 16 : 128, span.count * stride)
    }
  }

  private func planeRows(_ rows: Range<Int>, plane: Int, of target: CVPixelBuffer) -> Range<Int> {
    let planeHeight = CVPixelBufferGetHeightOfPlane(target, plane)
    let lower = rows.lowerBound * planeHeight / layout.height
    let upper = min(planeHeight, (rows.upperBound * planeHeight + layout.height - 1) / layout.height)
    return lower..<upper
  }

  private mutating func make(_ pixelFormat: OSType) throws -> CVPixelBuffer {
    let pool =
      try self.pool.flatMap { $0.pixelFormat == pixelFormat ? $0.pool : nil } ?? Self.pool(layout, pixelFormat)
    self.pool = (pixelFormat, pool)
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw ScreenSharingError.codec("Allocate frame", status) }

    return buffer
  }

  private static func pool(_ layout: ScreenSharingV2TileLayout, _ pixelFormat: OSType) throws -> CVPixelBufferPool {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: pixelFormat,
      kCVPixelBufferWidthKey: layout.width,
      kCVPixelBufferHeightKey: layout.height,
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw ScreenSharingError.codec("Create frame pool", status) }

    return pool
  }
}
