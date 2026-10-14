#if os(macOS)
  import CoreVideo
  import Foundation
  import IOSurface
  import QuartzCore

  public final class VNCFramePublisher: @unchecked Sendable {
    public init() {}
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var stale: [IOSurfaceID: [RFBRectangle]?] = [:]
    static let maximumPendingRectangles = 256
    static let maximumTrackedBuffers = 8

    public func publish(
      _ framebuffer: RFBFramebuffer, changed: [RFBRectangle]?, to mailbox: ScreenSharingFrameMailbox,
      metrics: ScreenSharingMetrics
    ) {
      if poolWidth != framebuffer.width || poolHeight != framebuffer.height { stale = [:] }
      guard let pixelBuffer = makePixelBuffer(width: framebuffer.width, height: framebuffer.height),
        let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
      else {
        metrics.increment("vncPixelBufferFailures")
        return
      }
      let id = IOSurfaceGetID(surface)
      let pending: [RFBRectangle]? =
        if let backlog = stale[id], let backlog, let changed { backlog + changed } else { nil }
      let full = RFBRectangle(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
      let regions = pending.map { Self.coalesce($0, full: full) } ?? [full]
      let copied = copy(framebuffer, regions: regions, into: pixelBuffer)
      metrics.increment("vncBytesCopied", by: copied)
      for other in stale.keys where other != id {
        if let changed, let backlog = stale[other], let backlog {
          stale[other] = backlog.count + changed.count > Self.maximumPendingRectangles ? .some(nil) : backlog + changed
        } else {
          stale[other] = .some(nil)
        }
      }
      stale[id] = .some([])
      if stale.count > Self.maximumTrackedBuffers {
        for key in stale.keys.filter({ $0 != id }).prefix(stale.count - Self.maximumTrackedBuffers) {
          stale[key] = nil
        }
      }
      mailbox.put(
        ScreenSharingVideoFrame(
          pixelBuffer: pixelBuffer, timestampNs: ScreenSharingMetrics.nowNs, receivedAtSeconds: CACurrentMediaTime()))
      metrics.increment("vncUpdatesPublished")
    }

    static func coalesce(_ regions: [RFBRectangle], full: RFBRectangle) -> [RFBRectangle] {
      var seen = Set<RFBRectangle>()
      let unique = regions.filter { seen.insert($0).inserted }
      let area = unique.reduce(0) { $0 + max(0, $1.width) * max(0, $1.height) }
      if unique.count > maximumPendingRectangles || area >= full.width * full.height { return [full] }
      return unique
    }

    private func copy(_ framebuffer: RFBFramebuffer, regions: [RFBRectangle], into pixelBuffer: CVPixelBuffer) -> Int {
      CVPixelBufferLockBaseAddress(pixelBuffer, [])
      defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
      guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
      let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
      var copied = 0
      framebuffer.withPixels { source, sourceStride in
        guard let base = source.baseAddress else { return }
        for region in regions {
          let x = max(0, region.x), y = max(0, region.y)
          let maxX = min(framebuffer.width, region.maxX), maxY = min(framebuffer.height, region.maxY)
          guard maxX > x, maxY > y else { continue }
          let rowBytes = (maxX - x) * 4
          if x == 0, maxX == framebuffer.width, destinationStride == sourceStride {
            (destination + y * destinationStride).copyMemory(
              from: base + y * sourceStride, byteCount: sourceStride * (maxY - y))
          } else {
            for row in y..<maxY {
              (destination + row * destinationStride + x * 4).copyMemory(
                from: base + row * sourceStride + x * 4, byteCount: rowBytes)
            }
          }
          copied += rowBytes * (maxY - y)
        }
      }
      return copied
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
      if pool == nil || poolWidth != width || poolHeight != height {
        let attributes: [CFString: Any] = [
          kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey: width,
          kCVPixelBufferHeightKey: height,
          kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
          kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess else {
          return nil
        }
        pool = created
        poolWidth = width
        poolHeight = height
      }
      guard let pool else { return nil }
      var pixelBuffer: CVPixelBuffer?
      guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess else { return nil }
      return pixelBuffer
    }
  }
#endif
