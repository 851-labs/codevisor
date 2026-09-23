#if os(macOS)
  import ScreenSharing
  import CoreVideo
  import Foundation
  import QuartzCore

  /// Copies the RFB framebuffer into pooled, IOSurface-backed BGRA pixel
  /// buffers the Metal renderer draws directly. Called from the client's read
  /// loop only, one update at a time, so it is unchecked rather than locked.
  public final class VNCFramePublisher: @unchecked Sendable {
    public init() {}
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    public func publish(
      _ framebuffer: RFBFramebuffer, to mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics
    ) {
      guard let pixelBuffer = makePixelBuffer(width: framebuffer.width, height: framebuffer.height) else {
        metrics.increment("vncPixelBufferFailures")
        return
      }
      CVPixelBufferLockBaseAddress(pixelBuffer, [])
      if let destination = CVPixelBufferGetBaseAddress(pixelBuffer) {
        let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        framebuffer.withPixels { source, sourceStride in
          if destinationStride == sourceStride {
            destination.copyMemory(from: source.baseAddress!, byteCount: sourceStride * framebuffer.height)
          } else {
            for row in 0..<framebuffer.height {
              (destination + row * destinationStride).copyMemory(
                from: source.baseAddress! + row * sourceStride, byteCount: sourceStride)
            }
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
      // What 851-2319 (copy only changed rectangles) brings down; vnc-bench reports it per update.
      metrics.increment("vncBytesCopied", by: framebuffer.bytesPerRow * framebuffer.height)
      mailbox.put(
        ScreenSharingVideoFrame(
          pixelBuffer: pixelBuffer, timestampNs: ScreenSharingMetrics.nowNs, receivedAtSeconds: CACurrentMediaTime()))
      metrics.increment("vncUpdatesPublished")
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
