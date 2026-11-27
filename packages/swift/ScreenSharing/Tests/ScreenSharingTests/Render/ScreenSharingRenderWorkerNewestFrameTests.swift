#if os(macOS)
  import CoreVideo
  import MetalKit
  import Testing

  @testable import ScreenSharing

  @MainActor
  struct ScreenSharingRenderWorkerNewestFrameTests {
    private let worker: ScreenSharingMetalPreparer
    private let metrics = ScreenSharingMetrics()

    init() throws {
      let device = try #require(MTLCreateSystemDefaultDevice(), "This machine has no Metal device to render with")
      let layer = CAMetalLayer()
      layer.device = device
      worker = ScreenSharingMetalPreparer(
        layer: layer,
        encoder: try ScreenSharingMetalEncoder(
          device: device, commandQueue: try #require(device.makeCommandQueue()),
          pipelines: .init(device: device, shader: ScreenSharingMetalView.shader)),
        metrics: metrics)
    }

    private final class Newer: @unchecked Sendable {
      let frame: ScreenSharingVideoFrame
      var taken = 0
      init(_ frame: ScreenSharingVideoFrame) { self.frame = frame }
    }

    private static func frame(format: OSType, rtp: UInt32) throws -> ScreenSharingVideoFrame {
      var pixel: CVPixelBuffer?
      let attributes =
        [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        as CFDictionary
      #expect(CVPixelBufferCreate(nil, 64, 64, format, attributes, &pixel) == kCVReturnSuccess)
      return .init(pixelBuffer: try #require(pixel), timestampNs: Int64(rtp), rtpTimestamp: rtp)
    }

    private static func request(newer: Newer) throws -> ScreenSharingPreparationRequest {
      var request = ScreenSharingPreparationRequest(
        frame: try frame(format: kCVPixelFormatType_32BGRA, rtp: 1), isNewFrame: true,
        geometry: .init(clearColor: SIMD4(0, 0, 0, 1), drawableSize: CGSize(width: 64, height: 64)), queuedAtNs: 0)
      request.newer = {
        newer.taken += 1
        return newer.frame
      }
      return request
    }

    @Test func aDrawableThatCameAtOnceKeepsTheChosenFrameAndLeavesTheNewerOneQueued() throws {
      let newer = Newer(try Self.frame(format: kCVPixelFormatType_32BGRA, rtp: 2))

      let result = worker.newer(than: try Self.request(newer: newer), in: .standard, afterWaitingNs: 400_000)

      #expect(result.replacement == nil && result.deferred == nil && newer.taken == 0)
    }

    @Test func aFrameThatArrivedDuringALongDrawableWaitIsDrawnInstead() throws {
      let newer = Newer(try Self.frame(format: kCVPixelFormatType_32BGRA, rtp: 2))

      let result = worker.newer(than: try Self.request(newer: newer), in: .standard, afterWaitingNs: 14_700_000)

      #expect(result.replacement?.0.rtpTimestamp == 2 && result.deferred == nil && newer.taken == 1)
      #expect(metrics.counter("renderFramesReplacedAfterDrawableWait") == 1)
    }

    @Test func aNewerFrameInAnotherDynamicRangeIsHandedBackForTheNextDraw() throws {
      let newer = Newer(try Self.frame(format: ScreenSharingDynamicRange.highCapturePixelFormat, rtp: 2))

      let result = worker.newer(than: try Self.request(newer: newer), in: .standard, afterWaitingNs: 14_700_000)

      #expect(result.replacement == nil && result.deferred?.rtpTimestamp == 2)
      #expect(metrics.counter("renderFramesDeferredAfterDrawableWait") == 1)
    }
  }
#endif
