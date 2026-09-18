import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingBufferTests {
  @Test func cadenceSeparatesClocksAndRebasesAfterTimestampRegression() throws {
    let metrics = ScreenSharingMetrics()
    metrics.event("capture", atNanoseconds: 10_000_000)
    metrics.event("capture", atNanoseconds: 26_000_000)
    metrics.event("capture", atNanoseconds: 26_000_000)
    metrics.event("capture", atNanoseconds: -1)
    metrics.event("capture", atNanoseconds: 2_000_000)
    metrics.event("capture", atNanoseconds: 35_000_000)
    metrics.event("decode", atNanoseconds: 1_000_000_000)
    metrics.event("decode", atNanoseconds: 1_010_000_000)
    let capture = try #require(metrics.snapshot().timings["capture"])
    #expect(capture.count == 3)
    #expect(capture.p50Ms == 16)
    #expect(capture.maximumMs == 33)
    #expect(metrics.snapshot().timings["decode"]?.p50Ms == 10)
  }

  @Test func slowConsumerReceivesNewestFrameAndReleasesQueuedFrame() throws {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let buffer = try #require(pixel)
    let mailbox = ScreenSharingFrameMailbox()
    for timestamp in 1...100 {
      mailbox.put(ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: Int64(timestamp)))
    }
    #expect(mailbox.droppedFrames == 99)
    #expect(mailbox.take()?.timestampNs == 100)
    #expect(mailbox.take() == nil)
    mailbox.put(ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: 101))
    mailbox.clear()
    #expect(mailbox.take() == nil)
    #expect(mailbox.droppedFrames == 99)
  }

  @Test func metricsBoundHistoryAndRejectInvalidDurations() throws {
    let metrics = ScreenSharingMetrics()
    for value in 0..<2000 { metrics.observe("encode", milliseconds: Double(value)) }
    metrics.observe("encode", milliseconds: .infinity)
    metrics.observe("encode", milliseconds: .nan)
    metrics.observe("encode", milliseconds: -1)
    let timing = try #require(metrics.snapshot().timings["encode"])
    #expect(timing.count == 1800)
    #expect(timing.p50Ms == 1100)
    #expect(timing.p95Ms == 1910)
    #expect(timing.maximumMs == 1999)
  }

  @Test func rendererNotificationsAreBoundedUntilMailboxIsDrained() throws {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let buffer = try #require(pixel)
    let mailbox = ScreenSharingFrameMailbox()
    let notifications = ScreenSharingMetrics()
    mailbox.onFrameAvailable { notifications.increment("available") }
    for timestamp in 1...100 {
      mailbox.put(ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: Int64(timestamp)))
    }
    #expect(notifications.snapshot().counters["available"] == 1)
    #expect(mailbox.take()?.timestampNs == 100)
    mailbox.put(ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: 101))
    #expect(notifications.snapshot().counters["available"] == 2)
    mailbox.onFrameAvailable(nil)
    mailbox.clear()
    mailbox.put(ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: 102))
    #expect(notifications.snapshot().counters["available"] == 2)
    mailbox.onFrameAvailable { notifications.increment("available") }
    #expect(notifications.snapshot().counters["available"] == 3)
  }

  @Test(arguments: [0, 63, 1921, 3842])
  func rejectsUnsupportedWidths(_ width: Int) {
    #expect(throws: (any Error).self) { try ScreenSharingVideoConfiguration(width: width) }
  }
}
