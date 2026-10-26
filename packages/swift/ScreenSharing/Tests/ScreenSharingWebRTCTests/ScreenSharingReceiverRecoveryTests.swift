import CodevisorTestSupport
import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC
@preconcurrency import WebRTC

@MainActor
struct ScreenSharingReceiverRecoveryTests {
  @MainActor
  final class Harness {
    let clock = TestClock()
    let metrics = ScreenSharingMetrics()
    let codecFactory: ScreenSharingCodecFactory
    let channel = RefreshChannelDouble()
    let recovery: ScreenSharingReceiverRecovery
    static let requesterInterval = Duration.milliseconds(100)
    var audit: ScreenSharingDeliveryAudit { codecFactory.deliveryAudit }

    init(
      grace: Duration = ScreenSharingDeliveryVerifier.defaultGrace,
      graceExtensions: Int = ScreenSharingDeliveryVerifier.defaultGraceExtensions
    ) {
      let clock = clock
      let origin = clock.now
      let metrics = metrics
      codecFactory = ScreenSharingCodecFactory(metrics: metrics)
      recovery = ScreenSharingReceiverRecovery(
        metrics: metrics, codecFactory: codecFactory, videoRefresh: channel, grace: grace,
        graceExtensions: graceExtensions,
        nowNs: { nanoseconds(origin.duration(to: clock.now)) },
        sleep: { try await clock.sleep(for: $0) })
    }

    var counters: [String: Int] { metrics.snapshot().counters }
    var labels: [String: String] { metrics.snapshot().labels }

    func decodeRecoveryKeyframe() {
      codecFactory.refreshSignal.decodedKeyframe(generation: codecFactory.refreshSignal.keyframeGeneration)
    }

    func requestRefresh(after grace: Duration, decoded: Int64, target: Int64) async {
      audit.decoded(sourceTimestampNs: decoded, nowNs: 1)
      recovery.handle(.sourceIdle(latestTimestampNs: target))
      await clock.waitForSleep(grace)
      clock.advance(by: grace)
      await channel.sends.wait()
      await clock.waitForSleep(Self.requesterInterval)
    }

    func awaitSignalHop(_ trigger: () -> Void) async {
      let revision = clock.changed.value
      trigger()
      await clock.changed.wait(for: revision + 1)
    }

    func close() async {
      for task in recovery.close() { await task.value }
    }
  }

  @Test func aNoticeAlreadyCoveredByDecodedContentIsVerifiedWithoutStartingATimer() async {
    let harness = Harness(grace: .milliseconds(250), graceExtensions: 0)
    harness.audit.decoded(sourceTimestampNs: 500, nowNs: 7)
    harness.recovery.handle(.sourceIdle(latestTimestampNs: 400))
    #expect(harness.counters["sourceIdleNoticesReceived"] == 1)
    #expect(harness.counters["sourceIdleVerified"] == 1)
    #expect(harness.labels["sourceIdleOutcome"] == "verified at notice")
    #expect(harness.labels["sourceIdleNoticeDecodedTimestampNs"] == "500")
    #expect(harness.labels["sourceIdleNoticeTargetTimestampNs"] == "400")
    #expect(harness.labels["sourceIdleTargetDecodedAtNs"] == "7")
    #expect(harness.clock.pendingCount == 0 && harness.channel.sent.isEmpty)
    harness.recovery.handle(.keyframe)
    #expect(harness.counters["sourceIdleNoticesReceived"] == 1)
    await harness.close()
  }

  @Test func contentThatArrivesDuringGraceIsVerifiedWithoutRequestingAnything() async {
    let grace = Duration.milliseconds(250)
    let harness = Harness(grace: grace, graceExtensions: 0)
    harness.audit.decoded(sourceTimestampNs: 100, nowNs: 1)
    harness.recovery.handle(.sourceIdle(latestTimestampNs: 900))
    await harness.clock.waitForSleep(grace)
    #expect(harness.counters["sourceIdleVerifiedAfterGrace"] == nil)

    harness.audit.decoded(sourceTimestampNs: 900, nowNs: 2)
    let verification = harness.recovery.pendingDeliveryVerification
    #expect(verification != nil)
    harness.clock.advance(by: grace)
    await verification?.value
    #expect(harness.counters["sourceIdleVerifiedAfterGrace"] == 1)
    #expect(harness.labels["sourceIdleOutcome"] == "verified during grace")
    #expect(harness.labels["sourceIdleTargetDecodedAtNs"] == "2")
    #expect(harness.counters["sourceIdleRefreshRequests"] == nil)
    #expect(harness.channel.sent.isEmpty)
    await harness.close()
  }

  @Test func anUnmetNoticeWaitsExactlyOneGraceThenDrivesTheKeyframeRequestPath() async {
    let grace = Duration.milliseconds(250)
    let harness = Harness(grace: grace, graceExtensions: 0)
    harness.audit.decoded(sourceTimestampNs: 100, nowNs: 1)
    harness.recovery.handle(.sourceIdle(latestTimestampNs: 900))
    await harness.clock.waitForSleep(grace)
    harness.clock.advance(by: grace - .nanoseconds(1))
    #expect(harness.counters["sourceIdleRefreshRequests"] == nil)
    #expect(harness.clock.pendingCount == 1)

    harness.clock.advance(by: .nanoseconds(1))
    await harness.channel.sends.wait()
    #expect(harness.channel.sent == [.keyframe])
    #expect(harness.counters["sourceIdleRefreshRequests"] == 1)
    #expect(harness.labels["sourceIdleOutcome"] == "refresh requested")
    #expect(harness.counters["sourceIdleRecoveryInitiated"] == 1)
    #expect(harness.counters["refreshRecoveryPendingEvents"] == 1)
    #expect(harness.counters["videoRefreshRequestsSent"] == 1)
    #expect(harness.labels["sourceIdleRequestSentAtNs"] != nil)

    await harness.clock.waitForSleep(Harness.requesterInterval)
    harness.clock.advance(by: Harness.requesterInterval)
    await harness.channel.sends.wait(for: 2)
    #expect(harness.channel.sent == [.keyframe, .keyframe])
    #expect(harness.counters["videoRefreshRequestsSent"] == 2)
    #expect(harness.counters["sourceIdleRefreshRequests"] == 1)
    await harness.close()
    #expect(harness.clock.pendingCount == 0)
  }

  @Test func theProductGraceAndExtensionDefaultsApply() async {
    let grace = ScreenSharingDeliveryVerifier.defaultGrace
    let allowed = ScreenSharingDeliveryVerifier.defaultGraceExtensions
    let harness = Harness()
    harness.audit.decoded(sourceTimestampNs: 100, nowNs: 1)
    harness.recovery.handle(.sourceIdle(latestTimestampNs: 900))
    await harness.clock.waitForSleep(grace)
    for extended in 1...allowed {
      harness.audit.decoded(sourceTimestampNs: 100 + Int64(extended), nowNs: Int64(extended))
      harness.clock.advance(by: grace)
      await harness.clock.waitForSleep(grace, count: extended + 1)
      #expect(harness.counters["sourceIdleGraceExtensions"] == extended)
      #expect(harness.counters["sourceIdleRefreshRequests"] == nil)
    }
    harness.audit.decoded(sourceTimestampNs: 200, nowNs: 9)
    harness.clock.advance(by: grace)
    await harness.channel.sends.wait()
    #expect(harness.counters["sourceIdleGraceExtensions"] == allowed)
    #expect(harness.counters["sourceIdleRefreshRequests"] == 1)
    await harness.close()
  }

  @Test func aGraceWindowWithoutNewerContentIsNotExtended() async {
    let grace = Duration.milliseconds(250)
    let harness = Harness(grace: grace, graceExtensions: 4)
    harness.audit.decoded(sourceTimestampNs: 100, nowNs: 1)
    harness.recovery.handle(.sourceIdle(latestTimestampNs: 900))
    await harness.clock.waitForSleep(grace)
    harness.audit.decoded(sourceTimestampNs: 100, nowNs: 2)
    harness.audit.decoded(sourceTimestampNs: 50, nowNs: 3)
    harness.clock.advance(by: grace)
    await harness.channel.sends.wait()
    #expect(harness.counters["sourceIdleGraceExtensions"] == nil)
    #expect(harness.counters["sourceIdleRefreshRequests"] == 1)
    #expect(harness.clock.requestCount(grace) == 1)
    await harness.close()
  }

  @Test func recoveryWithoutTheAnnouncedContentRetriesOnAnExponentialBackoff() async {
    let grace = Duration.milliseconds(250)
    let harness = Harness(grace: grace, graceExtensions: 0)
    await harness.requestRefresh(after: grace, decoded: 100, target: 900)
    var intervalSleeps = 1

    for retry in 1...3 {
      let delay = ScreenSharingDeliveryVerifier.retryDelay(retry)
      harness.decodeRecoveryKeyframe()
      if delay == Harness.requesterInterval {
        intervalSleeps += 1
        await harness.clock.waitForSleep(delay, count: intervalSleeps)
      } else {
        await harness.clock.waitForSleep(delay)
      }
      #expect(harness.counters["sourceIdleRefreshRetries"] == retry)
      #expect(harness.counters["refreshRecoveryClearedEvents"] == retry)

      harness.clock.advance(by: delay - .nanoseconds(1))
      #expect(harness.counters["sourceIdleRetriesExecuted"] == (retry == 1 ? nil : retry - 1))
      harness.clock.advance(by: .nanoseconds(1))
      await harness.channel.sends.wait(for: retry + 1)
      #expect(harness.counters["sourceIdleRetriesExecuted"] == retry)
      intervalSleeps += 1
      await harness.clock.waitForSleep(Harness.requesterInterval, count: intervalSleeps)
    }
    #expect(harness.clock.requestCount(.milliseconds(200)) == 1)
    #expect(harness.clock.requestCount(.milliseconds(400)) == 1)
    #expect(harness.counters["sourceIdleRecovered"] == nil)
    #expect(harness.counters["sourceIdleRefreshAlreadyPending"] == nil)
    #expect(harness.channel.sent == Array(repeating: .keyframe, count: 4))
    await harness.close()
    #expect(harness.clock.pendingCount == 0)
  }

  @Test func theRetryBackoffDoublesFromOneTenthOfASecondAndIsCappedAtFive() {
    #expect(ScreenSharingDeliveryVerifier.retryDelay(1) == .milliseconds(100))
    #expect(ScreenSharingDeliveryVerifier.retryDelay(2) == .milliseconds(200))
    #expect(ScreenSharingDeliveryVerifier.retryDelay(6) == .milliseconds(3_200))
    #expect(ScreenSharingDeliveryVerifier.retryDelay(7) == .milliseconds(5_000))
    #expect(ScreenSharingDeliveryVerifier.retryDelay(40) == .milliseconds(5_000))
    #expect(ScreenSharingDeliveryVerifier.retryDelay(0) == .milliseconds(100))
  }

  @Test func aKeyframeCarryingTheAnnouncedContentEndsRecoveryWithoutARetry() async {
    let grace = Duration.milliseconds(250)
    let harness = Harness(grace: grace, graceExtensions: 0)
    await harness.requestRefresh(after: grace, decoded: 100, target: 900)

    harness.audit.decoded(sourceTimestampNs: 950, nowNs: 4)
    await harness.awaitSignalHop { harness.decodeRecoveryKeyframe() }
    #expect(harness.counters["sourceIdleRecovered"] == 1)
    #expect(harness.labels["sourceIdleOutcome"] == "recovered after refresh")
    #expect(harness.labels["sourceIdleTargetDecodedAtNs"] == "4")
    #expect(harness.counters["sourceIdleRefreshRetries"] == nil)
    #expect(harness.counters["refreshRecoveryClearedEvents"] == 1)
    #expect(harness.clock.pendingCount == 0)
    #expect(harness.channel.sent == [.keyframe])
    await harness.close()
  }

  @Test func aNewerNoticeReplacesThePendingOneAndItsRetrySchedule() async {
    let grace = Duration.milliseconds(250)
    let harness = Harness(grace: grace, graceExtensions: 0)
    await harness.requestRefresh(after: grace, decoded: 100, target: 900)
    harness.decodeRecoveryKeyframe()
    await harness.clock.waitForSleep(ScreenSharingDeliveryVerifier.retryDelay(1), count: 2)
    #expect(harness.counters["sourceIdleRefreshRetries"] == 1)

    harness.recovery.handle(.sourceIdle(latestTimestampNs: 1_200))
    await harness.clock.waitForSleep(grace, count: 2)
    #expect(harness.clock.pendingCount == 1)
    #expect(harness.audit.pendingTargetNs == 1_200)
    harness.clock.advance(by: grace)
    await harness.channel.sends.wait(for: 2)
    #expect(harness.counters["sourceIdleRetriesExecuted"] == nil)
    #expect(harness.counters["sourceIdleRefreshRequests"] == 2)
    #expect(harness.counters["sourceIdleRefreshAlreadyPending"] == nil)
    #expect(harness.counters["sourceIdleRecoveryInitiated"] == 2)
    await harness.close()
  }

  @Test func aDeferredKeyframeRequestGoesOutWhenTheChannelWakesUp() async {
    let grace = Duration.milliseconds(250)
    let harness = Harness(grace: grace, graceExtensions: 0)
    harness.channel.isAvailable = false
    harness.audit.decoded(sourceTimestampNs: 100, nowNs: 1)
    harness.recovery.handle(.sourceIdle(latestTimestampNs: 900))
    await harness.clock.waitForSleep(grace)
    harness.clock.advance(by: grace)
    await harness.clock.waitForSleep(Harness.requesterInterval)
    #expect(harness.counters["sourceIdleRefreshRequests"] == 1)
    #expect(harness.channel.sent.isEmpty && harness.counters["videoRefreshRequestsSent"] == nil)

    harness.channel.isAvailable = true
    harness.recovery.wake()
    #expect(harness.channel.sent == [.keyframe])
    #expect(harness.counters["videoRefreshRequestsSent"] == 1)
    await harness.close()
    #expect(harness.clock.pendingCount == 0)
  }
}
