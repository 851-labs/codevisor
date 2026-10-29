import CoreMedia
import ScreenCaptureKit
import ScreenSharingBench
import Testing

struct BenchCapturedFrameTests {
  private static let hostClockTicksPerSecond: Int32 = 24_000_000

  @Test func aCompleteFrameIsReadAtItsPresentationTimeOnTheContinuousClock() throws {
    let frame = try Self.sampleBuffer(
      version: 1_234, presentedAtTicks: 5 * Int64(Self.hostClockTicksPerSecond), status: .complete)

    let observation = try #require(
      try BenchCapturedFrame.observation(of: frame, layout: .standard, callbackNs: 9, continuousMinusAbsoluteNs: 700))

    #expect(observation.version == 1_234)
    #expect(observation.ptsNs == 5_000_000_700)
    #expect(observation.callbackNs == 9)
  }

  @Test(arguments: [SCFrameStatus.idle, .blank, .suspended, .started, .stopped])
  func framesWithoutNewContentAreNotObservations(_ status: SCFrameStatus) throws {
    let frame = try Self.sampleBuffer(version: 1, presentedAtTicks: 1, status: status)

    #expect(
      try BenchCapturedFrame.observation(of: frame, layout: .standard, callbackNs: 0, continuousMinusAbsoluteNs: 0)
        == nil)
  }

  private static func sampleBuffer(
    version: Int, presentedAtTicks: Int64, status: SCFrameStatus
  ) throws -> CMSampleBuffer {
    let image = try BenchPixelBuffers.make(width: BenchBarcodeLayout.standard.width, height: 64)
    BenchPixelBuffers.fill(image, gray: 0x40)
    try BenchBarcode.draw(version, into: image)
    let format = try CMVideoFormatDescription(imageBuffer: image)
    let timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMTime(value: presentedAtTicks, timescale: hostClockTicksPerSecond),
      decodeTimeStamp: .invalid)
    let sample = try CMSampleBuffer(imageBuffer: image, formatDescription: format, sampleTiming: timing)
    attach(status, to: sample)
    return sample
  }

  private static func attach(_ status: SCFrameStatus, to sample: CMSampleBuffer) {
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)!
    let info = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(
      info, Unmanaged.passUnretained(SCStreamFrameInfo.status.rawValue as CFString).toOpaque(),
      Unmanaged.passUnretained(status.rawValue as CFNumber).toOpaque())
  }
}
