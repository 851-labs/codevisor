import CodevisorTestSupport
import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingVideoRefreshTests {
  @Test func refreshProtocolRejectsUnknownAndTrailingBytes() throws {
    #expect(try ScreenSharingVideoRefreshMessage.decode(Data([1])).encoded() == Data([1]))
    for bytes in [Data(), Data([0]), Data([2]), Data([1, 1])] {
      #expect(throws: (any Error).self) { try ScreenSharingVideoRefreshMessage.decode(bytes) }
    }
  }

  @Test func failedDecodeCoalescesNotificationsAndRejectsOldKeyframeCompletion() {
    let signal = ScreenSharingRefreshSignal()
    let metrics = ScreenSharingMetrics()
    signal.onChange { event in
      // Reentry verifies notifications do not hold the signal's lock.
      _ = signal.keyframeGeneration
      metrics.increment(event.needed ? "requested" : "recovered")
    }
    signal.request()
    let old = signal.keyframeGeneration
    signal.request(resetDecoder: true)
    #expect(metrics.snapshot().counters["requested"] == 1)
    signal.decodedKeyframe(generation: old)
    #expect(metrics.snapshot().counters["recovered"] == nil)
    // A callback cannot acknowledge recovery before the invalid session has
    // been handed back to the decoder queue for reset.
    signal.decodedKeyframe(generation: signal.keyframeGeneration)
    #expect(metrics.snapshot().counters["recovered"] == nil)
    #expect(signal.consumeDecoderReset())
    #expect(!signal.consumeDecoderReset())
    signal.decodedKeyframe(generation: signal.keyframeGeneration)
    #expect(metrics.snapshot().counters["recovered"] == 1)
    signal.close()
    signal.request()
    #expect(metrics.snapshot().counters["requested"] == 1)
  }

  @Test func subscriptionReceivesPendingRequestAndCannotReopenClosedSignal() {
    let signal = ScreenSharingRefreshSignal()
    let metrics = ScreenSharingMetrics()
    signal.request()
    signal.onChange { _ in metrics.increment("events") }
    #expect(metrics.snapshot().counters["events"] == 1)
    signal.close()
    signal.onChange { _ in metrics.increment("events") }
    signal.request()
    #expect(metrics.snapshot().counters["events"] == 1)
  }

  @Test func externalEncoderRequestsCoalesceUntilConsumed() {
    let request = ScreenSharingEncoderRefreshRequest()
    #expect(!request.consume())
    request.request()
    request.request()
    #expect(request.consume())
    #expect(!request.consume())
  }

  @Test func refreshRateIsBoundedAcrossBurstsAndClockRegression() {
    var limit = ScreenSharingRefreshRateLimit()
    for (time, expected) in [
      (-1, false), (0, true), (0, false), (99_999_999, false),
      (100_000_000, true), (99_000_000, false), (199_999_999, false), (200_000_000, true),
    ] {
      let allowed = limit.allow(nowNs: Int64(time))
      #expect(allowed == expected)
    }
  }

  @Test @MainActor func recoveryRetriesOnlyUntilCurrentKeyframeAndCancelsOnClose() async {
    let clock = TestClock()
    let origin = clock.now
    var available = false
    var sends = 0
    let requester = ScreenSharingRefreshRequester(
      available: { available },
      send: {
        sends += 1; return true
      },
      nowNs: {
        let parts = origin.duration(to: clock.now).components
        return parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
      }, sleep: { try await clock.sleep(for: $0) })
    requester.update(.init(revision: 1, needed: true))
    await clock.waitForSleep(.milliseconds(100))
    #expect(sends == 0)
    available = true
    requester.wake()
    requester.wake()
    #expect(sends == 1)
    clock.advance(by: .milliseconds(99))
    requester.wake()
    #expect(sends == 1)
    clock.advance(by: .milliseconds(1))
    await clock.waitForSleep(.milliseconds(100), count: 2)
    #expect(sends == 2)
    requester.update(.init(revision: 2, needed: false))
    #expect(clock.pendingCount == 0)
    requester.update(.init(revision: 1, needed: true))
    clock.advance(by: .seconds(10))
    requester.wake()
    #expect(sends == 2)
    requester.update(.init(revision: 3, needed: true))
    await clock.waitForSleep(.milliseconds(100), count: 3)
    #expect(sends == 3)
    let pending = requester.close()
    await pending?.value
    #expect(clock.pendingCount == 0)
    requester.update(.init(revision: 4, needed: true))
    requester.wake()
    #expect(sends == 3)
  }

  @Test func cachedRefreshUsesLatestBufferAndStrictlyIncreasingTimestamps() throws {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let buffer = try #require(pixel)
    var store = ScreenSharingRefreshFrameStore()
    let empty = store.refresh(nowNs: 1)
    #expect(empty == nil)
    let captured = store.capture(.init(pixelBuffer: buffer, timestampNs: 10))
    #expect(captured?.timestampNs == 10 && captured?.sourceTimestampNs == 10)
    let refreshed = store.refresh(nowNs: 5)
    #expect(refreshed?.timestampNs == 11 && refreshed?.sourceTimestampNs == 10)
    #expect(refreshed?.pixelBuffer === buffer)
    let duplicate = store.capture(.init(pixelBuffer: buffer, timestampNs: 10))
    #expect(duplicate == nil)
    var nextPixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 32, 16, kCVPixelFormatType_32BGRA, nil, &nextPixel) == kCVReturnSuccess)
    let next = try #require(nextPixel)
    let replacement = store.capture(.init(pixelBuffer: next, timestampNs: 20))
    #expect(replacement?.timestampNs == 20 && replacement?.sourceTimestampNs == 20)
    let latest = store.refresh(nowNs: 30)
    #expect(latest?.timestampNs == 30 && latest?.sourceTimestampNs == 20)
    #expect(latest?.pixelBuffer === next)
    store.clear()
    let cleared = store.refresh(nowNs: 40)
    #expect(cleared == nil)
    let outOfOrder = store.capture(.init(pixelBuffer: buffer, timestampNs: 19))
    #expect(outOfOrder == nil)
    let maximum = store.capture(.init(pixelBuffer: buffer, timestampNs: Int64.max))
    #expect(maximum?.timestampNs == Int64.max)
    let overflow = store.refresh(nowNs: Int64.max)
    #expect(overflow == nil)
    let unsubmittable = store.capture(.init(pixelBuffer: buffer, timestampNs: Int64.max))
    #expect(unsubmittable == nil)
  }

  @Test func delayedNewerCaptureReplacesARefreshedOlderFrameWithMonotonicSubmission() throws {
    var first: CVPixelBuffer?
    var second: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &first) == kCVReturnSuccess)
    #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &second) == kCVReturnSuccess)
    let a = try #require(first)
    let b = try #require(second)
    var store = ScreenSharingRefreshFrameStore()
    #expect(store.capture(.init(pixelBuffer: a, timestampNs: 10))?.timestampNs == 10)
    #expect(store.refresh(nowNs: 30)?.timestampNs == 30)
    // Capture B (PTS 20) was produced before the refresh but delivered late.
    let late = store.capture(.init(pixelBuffer: b, timestampNs: 20))
    #expect(late?.pixelBuffer === b && late?.timestampNs == 31 && late?.sourceTimestampNs == 20)
    let refreshedB = store.refresh(nowNs: 25)
    #expect(refreshedB?.pixelBuffer === b && refreshedB?.timestampNs == 32 && refreshedB?.sourceTimestampNs == 20)
    // Actual duplicates and out-of-order captures remain rejected.
    #expect(store.capture(.init(pixelBuffer: b, timestampNs: 20)) == nil)
    #expect(store.capture(.init(pixelBuffer: a, timestampNs: 15)) == nil)
    #expect(store.capture(.init(pixelBuffer: a, timestampNs: -1)) == nil)
    let c = store.capture(.init(pixelBuffer: a, timestampNs: 21))
    #expect(c?.timestampNs == 33 && c?.sourceTimestampNs == 21)
    let ordinary = store.capture(.init(pixelBuffer: b, timestampNs: 100))
    #expect(ordinary?.timestampNs == 100 && ordinary?.sourceTimestampNs == 100)
  }
}
