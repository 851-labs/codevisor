#if os(macOS)
  import CoreGraphics
  import CoreVideo
  import ScreenCaptureKit
  import Testing
  @testable import ScreenSharing

  /// What the capture asks ScreenCaptureKit for in each dynamic range (851-2380). SDR is exactly
  /// what it was; HDR is the canonical HDR preset, whose format the encoder tags and the viewer draws.
  @MainActor struct ScreenSharingCaptureDynamicRangeTests {
    private func configuration(_ range: ScreenSharingDynamicRange) throws -> SCStreamConfiguration {
      let video = try ScreenSharingVideoConfiguration(
        width: 1920, height: 1200, framesPerSecond: 60, bitrate: 20_000_000)
      return ScreenSharingCapture.streamConfiguration(
        video,
        interval: try ScreenSharingCaptureIntervalRequest(videoFramesPerSecond: 60, overrideFramesPerSecond: nil),
        queueDepth: 3, pixelFormat: kCVPixelFormatType_32BGRA, showsCursor: false, capturesAudio: false,
        dynamicRange: range)
    }

    @Test func standardCapturesEightBitSRGBAsBefore() throws {
      let config = try configuration(.standard)
      #expect(config.pixelFormat == kCVPixelFormatType_32BGRA)
      #expect(config.colorSpaceName == CGColorSpace.sRGB)
      #expect(config.captureDynamicRange == .SDR)
    }

    @Test func highCapturesCanonicalTenBitDisplayP3PQ() throws {
      let config = try configuration(.high)
      #expect(config.captureDynamicRange == .hdrCanonicalDisplay)
      #expect(config.pixelFormat == ScreenSharingDynamicRange.highCapturePixelFormat)
      #expect(config.colorSpaceName == CGColorSpace.displayP3_PQ)
      #expect(config.colorMatrix == CGDisplayStream.yCbCrMatrix_ITU_R_709_2)
      // Everything else is the session's, as for SDR.
      #expect(config.width == 1920 && config.height == 1200 && config.queueDepth == 3 && !config.showsCursor)
      #expect(!config.scalesToFit || !config.preservesAspectRatio)
    }
  }
#endif
