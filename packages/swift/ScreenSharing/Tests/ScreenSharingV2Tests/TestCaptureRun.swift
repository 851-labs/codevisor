#if os(macOS)
  import CoreMedia
  import ScreenCaptureKit
  import Testing

  @testable import ScreenSharing

  struct TestCaptureRun {
    static let nothingChanged = [CGRect.zero]

    private let output: ScreenSharingCaptureOutput

    init(into sink: any ScreenSharingFrameSink) {
      output = ScreenSharingCaptureOutput(sink: sink, metrics: ScreenSharingMetrics()) { _ in }
    }

    func deliverFirstFrame(shades: [UInt8], timestampNs: Int64) throws {
      try deliver(shades: shades, timestampNs: timestampNs, dirtyRects: Self.nothingChanged)
    }

    func deliver(shades: [UInt8], timestampNs: Int64, dirtyRects: [CGRect]) throws {
      let pixels = try TestPixels.frame(shades: shades, timestampNs: timestampNs).pixelBuffer
      let sample = try Self.sample(pixels, presentationNs: timestampNs)
      let attachments =
        CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary]
      let frameInfo = try #require(attachments?.first)
      frameInfo[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
      frameInfo[SCStreamFrameInfo.contentScale.rawValue] = 1.0
      frameInfo[SCStreamFrameInfo.dirtyRects.rawValue] = dirtyRects.map { $0.dictionaryRepresentation }
      output.deliver(sample, of: .screen)
    }

    private static func sample(_ pixels: CVPixelBuffer, presentationNs: Int64) throws -> CMSampleBuffer {
      var format: CMFormatDescription?
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
      var timing = CMSampleTimingInfo(
        duration: .invalid, presentationTimeStamp: CMTime(value: presentationNs, timescale: 1_000_000_000),
        decodeTimeStamp: .invalid)
      var sample: CMSampleBuffer?
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: pixels, formatDescription: try #require(format), sampleTiming: &timing,
        sampleBufferOut: &sample)
      return try #require(sample)
    }
  }
#endif
