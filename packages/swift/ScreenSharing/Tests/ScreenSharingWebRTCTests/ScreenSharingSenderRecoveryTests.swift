import CodevisorTestSupport
import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC
@preconcurrency import WebRTC

/// The host's half of frame recovery as a state machine: keyframe requests under
/// the rate limit, the re-offer schedule while capture output is missing, and the
/// single idle notice. Nothing here negotiates; time is entirely virtual.
@MainActor
struct ScreenSharingSenderRecoveryTests {
  @MainActor
  final class Harness {
    let clock = TestClock()
    let metrics = ScreenSharingMetrics()
    let codecFactory: ScreenSharingCodecFactory
    let frameSender: ScreenSharingFrameSender
    let channel = RefreshChannelDouble()
    let recovery: ScreenSharingSenderRecovery
    var monitor: ScreenSharingSourceIdleMonitor { codecFactory.sourceIdleMonitor }

    init() {
      // The same boundary as production: trials are pinned before any RTC object exists.
      _ = ScreenSharingFieldTrials.process.ensureInstalled()
      let clock = clock
      let origin = clock.now
      let metrics = metrics
      codecFactory = ScreenSharingCodecFactory(metrics: metrics)
      frameSender = ScreenSharingFrameSender(
        source: RTCPeerConnectionFactory().videoSource(forScreenCast: true), metrics: metrics,
        idleMonitor: codecFactory.sourceIdleMonitor)
      recovery = ScreenSharingSenderRecovery(
        metrics: metrics, codecFactory: codecFactory, frameSender: frameSender, videoRefresh: channel,
        nowNs: { nanoseconds(origin.duration(to: clock.now)) },
        sleep: { try await clock.sleep(for: $0) })
    }

    /// Gives the one-frame cache something to re-offer, then pins the monitor's
    /// activity to virtual zero: `push` records the real monotonic clock, which
    /// the injected schedule must not be measured against.
    func captureFrame(timestampNs: Int64) throws {
      frameSender.configure(try ScreenSharingVideoConfiguration(width: 64, height: 64))
      var pixel: CVPixelBuffer?
      #expect(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
      frameSender.push(.init(pixelBuffer: try #require(pixel), timestampNs: timestampNs))
      #expect(frameSender.isHoldingCachedFrame)
      _ = monitor.recordSubmission(timestampNs: timestampNs, nowNs: 0)
    }

    var counters: [String: Int] { metrics.snapshot().counters }
    var labels: [String: String] { metrics.snapshot().labels }

    func close() async {
      for task in recovery.close() { await task.value }
      frameSender.stop()
      monitor.stop()
    }
  }

  @Test func keyframeRequestsAreAnsweredOncePerRateLimitWindowAndIdleNoticesAreIgnored() async throws {
    let harness = Harness()
    try harness.captureFrame(timestampNs: 1_000)
    harness.recovery.handle(.keyframe)
    #expect(harness.counters["videoRefreshRequestsReceived"] == 1)
    #expect(harness.counters["refreshFrames"] == 1)
    // The encoder is asked for a keyframe exactly once per admitted request.
    #expect(harness.codecFactory.encoderRefreshRequest.consume())
    #expect(!harness.codecFactory.encoderRefreshRequest.consume())

    harness.recovery.handle(.keyframe)
    #expect(harness.counters["videoRefreshRequestsReceived"] == 2)
    #expect(harness.counters["videoRefreshRequestsThrottled"] == 1)
    #expect(harness.counters["refreshFrames"] == 1)
    harness.clock.advance(by: .nanoseconds(ScreenSharingRefreshRateLimit.intervalNs - 1))
    harness.recovery.handle(.keyframe)
    #expect(harness.counters["videoRefreshRequestsThrottled"] == 2)
    #expect(harness.counters["refreshFrames"] == 1)
    harness.clock.advance(by: .nanoseconds(1))
    harness.recovery.handle(.keyframe)
    #expect(harness.counters["videoRefreshRequestsThrottled"] == 2)
    #expect(harness.counters["refreshFrames"] == 2)

    // The host never acts on its own idle notice, only on keyframe requests.
    harness.clock.advance(by: .seconds(1))
    harness.recovery.handle(.sourceIdle(latestTimestampNs: 1_000))
    #expect(harness.counters["videoRefreshRequestsReceived"] == 4)
    #expect(harness.counters["refreshFrames"] == 2)
    #expect(harness.channel.sent.isEmpty)
    await harness.close()
  }

  @Test func theLatestCaptureIsReOfferedFourTimesQuicklyThenAtTheSlowBoundedRate() async throws {
    let harness = Harness()
    let threshold = Duration.nanoseconds(ScreenSharingSourceIdleMonitor.defaultThresholdNs)
    let slow = Duration.nanoseconds(ScreenSharingSourceIdleMonitor.slowResubmissionIntervalNs)
    let quick = ScreenSharingSourceIdleMonitor.maximumQuickResubmissions
    try harness.captureFrame(timestampNs: 1_000)
    harness.recovery.activate()
    // The first evaluation happens immediately and parks until the threshold.
    await harness.clock.waitForSleep(threshold)
    #expect(harness.counters["sourceIdleEvaluations"] == 1)
    #expect(harness.counters["sourceIdleResubmissions"] == nil)

    harness.clock.advance(by: threshold - .nanoseconds(1))
    #expect(harness.counters["sourceIdleResubmissions"] == nil)
    #expect(harness.clock.pendingCount == 1)
    for offer in 1...quick {
      harness.clock.advance(by: offer == 1 ? .nanoseconds(1) : threshold)
      // Every re-offer is followed by the next scheduled evaluation, so waiting
      // for that registration proves the re-offer itself already happened.
      if offer == quick {
        await harness.clock.waitForSleep(slow)
      } else {
        await harness.clock.waitForSleep(threshold, count: offer + 1)
      }
      #expect(harness.counters["sourceIdleResubmissions"] == offer)
      #expect(harness.counters["refreshFrames"] == offer)
      #expect(harness.monitor.resubmissionCount == offer)
    }
    // The quick phase is exhausted: the host keeps re-offering, but slowly.
    #expect(harness.labels["sourceIdleState"] == "re-offering the latest capture at the slow bounded rate")

    // Output finally reached WebRTC, but the channel cannot carry the notice yet.
    harness.channel.isAvailable = false
    harness.monitor.recordEncoded(timestampNs: 1_000)
    harness.clock.advance(by: slow)
    await harness.channel.rejections.wait()
    #expect(harness.counters["sourceIdleNoticesDeferred"] == 1)
    #expect(harness.channel.sent.isEmpty)
    // Idle ends the loop: no timer runs while the desktop is quiet.
    #expect(harness.clock.pendingCount == 0)
    #expect(harness.counters["sourceIdleResubmissions"] == quick)

    harness.channel.isAvailable = true
    harness.recovery.flush()
    #expect(harness.channel.sent == [.sourceIdle(latestTimestampNs: 1_000)])
    #expect(harness.counters["sourceIdleNotices"] == 1)
    #expect(harness.labels["sourceIdleLatestTimestampNs"] == "1000")
    #expect(harness.labels["sourceIdleState"] == "latest capture announced")
    // The notice is announced once; a second flush has nothing left to send.
    harness.recovery.flush()
    #expect(harness.channel.sent.count == 1)
    await harness.close()
  }

  @Test func closingCancelsTheScheduledReOfferAndDropsTheRetainedNotice() async throws {
    let harness = Harness()
    let threshold = Duration.nanoseconds(ScreenSharingSourceIdleMonitor.defaultThresholdNs)
    try harness.captureFrame(timestampNs: 1_000)
    harness.channel.isAvailable = false
    harness.recovery.activate()
    await harness.clock.waitForSleep(threshold)

    let pending = harness.recovery.close()
    #expect(pending.count == 1)
    for task in pending { await task.value }
    // Cancellation resumed the parked sleeper and left no timer behind.
    #expect(harness.clock.pendingCount == 0)
    #expect(harness.counters["sourceIdleResubmissions"] == nil)
    // A closed recovery neither restarts its loop nor sends a retained notice.
    harness.recovery.activate()
    harness.channel.isAvailable = true
    harness.recovery.flush()
    #expect(harness.clock.pendingCount == 0)
    #expect(harness.channel.sent.isEmpty)
    #expect(harness.recovery.close().isEmpty)
    await harness.close()
  }
}
