import CodevisorTestSupport
import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingSourceIdleTests {
  private static let threshold: Int64 = 500_000_000

  private func nanoseconds(_ clock: TestClock, since origin: ContinuousClock.Instant) -> Int64 {
    let parts = origin.duration(to: clock.now).components
    return parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
  }

  @Test func idleNoticeProtocolRoundTripsAndRejectsMalformedBytes() throws {
    for value: Int64 in [0, 1, Int64.max] {
      let message = ScreenSharingVideoRefreshMessage.sourceIdle(latestTimestampNs: value)
      let encoded = message.encoded()
      #expect(encoded.count == 9 && encoded[0] == 2)
      #expect(try ScreenSharingVideoRefreshMessage.decode(encoded) == message)
    }
    #expect(try ScreenSharingVideoRefreshMessage.decode(Data([1])) == .keyframe)
    let negative = Data([2, 0x80, 0, 0, 0, 0, 0, 0, 0])
    let short = Data([2, 0, 0, 0, 0, 0, 0, 0])
    let long = Data([2, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    for bytes in [Data([2]), short, long, negative, Data([3, 1])] {
      #expect(throws: (any Error).self) { try ScreenSharingVideoRefreshMessage.decode(bytes) }
    }
  }

  @Test func monitorArmsOncePerActivityPeriodAndAnnouncesTheNewestEncodedContent() {
    let monitor = ScreenSharingSourceIdleMonitor(thresholdNs: Self.threshold)
    #expect(monitor.evaluate(nowNs: 0) == .inactive)
    #expect(monitor.recordSubmission(timestampNs: 10, nowNs: 0))
    #expect(!monitor.recordSubmission(timestampNs: 20, nowNs: 100))
    #expect(monitor.evaluate(nowNs: 100) == .wait(untilNs: 100 + Self.threshold))
    monitor.recordEncoded(timestampNs: 10)
    monitor.recordEncoded(timestampNs: 20)
    monitor.recordEncoded(timestampNs: 15)
    #expect(monitor.latestEncodedNs == 20)
    #expect(monitor.evaluate(nowNs: 99 + Self.threshold) == .wait(untilNs: 100 + Self.threshold))
    #expect(monitor.evaluate(nowNs: 100 + Self.threshold) == .idle(latestEncodedNs: 20))
    #expect(monitor.evaluate(nowNs: 100 + Self.threshold) == .inactive)
    #expect(monitor.recordSubmission(timestampNs: 30, nowNs: 200 + Self.threshold))
    monitor.recordEncoded(timestampNs: 30)
    #expect(monitor.evaluate(nowNs: 200 + 2 * Self.threshold) == .idle(latestEncodedNs: 30))
  }

  @Test func monitorReoffersUnencodedContentQuicklyThenAtASlowBoundedRateUntilItIsEncoded() {
    let slow: Int64 = 2_000_000_000
    let monitor = ScreenSharingSourceIdleMonitor(thresholdNs: Self.threshold, slowIntervalNs: slow)
    #expect(monitor.recordSubmission(timestampNs: 30, nowNs: 0))
    monitor.recordEncoded(timestampNs: 20)
    #expect(monitor.evaluate(nowNs: Self.threshold) == .resubmit)
    #expect(monitor.evaluate(nowNs: Self.threshold) == .wait(untilNs: 2 * Self.threshold))
    // A refresh re-offers the same buffer, so the encoded identity is the capture's.
    monitor.recordEncoded(timestampNs: 30)
    #expect(monitor.evaluate(nowNs: 2 * Self.threshold) == .idle(latestEncodedNs: 30))
    // Older encoded content is never announced as current; re-offers slow down.
    #expect(monitor.recordSubmission(timestampNs: 40, nowNs: 3 * Self.threshold))
    var now = 3 * Self.threshold
    for attempt in 1...ScreenSharingSourceIdleMonitor.maximumQuickResubmissions {
      now += Self.threshold
      #expect(monitor.evaluate(nowNs: now) == .resubmit)
      #expect(monitor.resubmissionCount == attempt)
    }
    #expect(monitor.evaluate(nowNs: now + Self.threshold) == .wait(untilNs: now + slow))
    #expect(monitor.evaluate(nowNs: now + slow) == .resubmit)
    #expect(monitor.evaluate(nowNs: now + slow) == .wait(untilNs: now + 2 * slow))
    #expect(monitor.latestEncodedNs == 30)
    monitor.recordEncoded(timestampNs: 40)
    #expect(monitor.evaluate(nowNs: now + 2 * slow) == .idle(latestEncodedNs: 40))
    #expect(monitor.evaluate(nowNs: now + 2 * slow) == .inactive)
    // The next capture resets the attempt budget to the quick threshold.
    #expect(monitor.recordSubmission(timestampNs: 50, nowNs: now + 2 * slow))
    #expect(monitor.resubmissionCount == 0)
    #expect(monitor.evaluate(nowNs: now + 2 * slow + Self.threshold) == .resubmit)
    monitor.recordEncoded(timestampNs: 50)
    #expect(monitor.evaluate(nowNs: now + 2 * slow + 2 * Self.threshold) == .idle(latestEncodedNs: 50))
    let nothingEncoded = ScreenSharingSourceIdleMonitor(thresholdNs: Self.threshold)
    #expect(nothingEncoded.recordSubmission(timestampNs: 1, nowNs: 0))
    #expect(nothingEncoded.evaluate(nowNs: Self.threshold) == .resubmit)
    nothingEncoded.stop()
    #expect(!nothingEncoded.recordSubmission(timestampNs: 2, nowNs: 0))
    #expect(nothingEncoded.evaluate(nowNs: 3 * Self.threshold) == .inactive)
  }

  @Test @MainActor func notifierWakesOncePerThresholdSendsOneNoticeAndRetainsItUntilTheChannelOpens() async {
    let clock = TestClock()
    let origin = clock.now
    let monitor = ScreenSharingSourceIdleMonitor(thresholdNs: Self.threshold, slowIntervalNs: 2_000_000_000)
    let attempted = TestSignal()
    let resubmitted = TestSignal()
    var available = false
    var notices: [Int64] = []
    let notifier = ScreenSharingSourceIdleNotifier(
      monitor: monitor,
      resubmit: { resubmitted.signal() },
      notify: {
        defer { attempted.signal() }
        guard available else { return false }
        notices.append($0)
        return true
      },
      nowNs: { nanoseconds(clock, since: origin) }, sleep: { try await clock.sleep(for: $0) })
    #expect(monitor.recordSubmission(timestampNs: 1, nowNs: 0))
    monitor.recordEncoded(timestampNs: 1)
    notifier.activate()
    notifier.activate()
    await clock.waitForSleep(.milliseconds(500))
    #expect(notices.isEmpty && clock.pendingCount == 1)
    clock.advance(by: .milliseconds(250))
    #expect(!monitor.recordSubmission(timestampNs: 2, nowNs: nanoseconds(clock, since: origin)))
    monitor.recordEncoded(timestampNs: 2)
    clock.advance(by: .milliseconds(250))
    // Activity during the wait defers the announcement by one more threshold.
    await clock.waitForSleep(.milliseconds(250))
    #expect(notices.isEmpty)
    clock.advance(by: .milliseconds(250))
    await attempted.wait(for: 1)
    // The channel was unavailable: the notice is retained, not lost.
    #expect(notices.isEmpty && notifier.hasPendingNotice && clock.pendingCount == 0)
    notifier.flush()
    #expect(notifier.hasPendingNotice && attempted.value == 2)
    available = true
    notifier.flush()
    #expect(notices == [2] && !notifier.hasPendingNotice && resubmitted.value == 0)
    // A dropped last frame is re-offered once; the announced content is the capture's.
    #expect(monitor.recordSubmission(timestampNs: 5, nowNs: nanoseconds(clock, since: origin)))
    notifier.activate()
    await clock.waitForSleep(.milliseconds(500), count: 2)
    clock.advance(by: .milliseconds(500))
    await resubmitted.wait(for: 1)
    await clock.waitForSleep(.milliseconds(500), count: 3)
    #expect(notices == [2])
    monitor.recordEncoded(timestampNs: 5)
    clock.advance(by: .milliseconds(500))
    // Attempts so far: unavailable, flush while unavailable, flush, this notice.
    await attempted.wait(for: 4)
    #expect(notices == [2, 5] && clock.pendingCount == 0)
    // Persistent failure keeps re-offering at the slow rate, never announcing stale content.
    #expect(monitor.recordSubmission(timestampNs: 8, nowNs: nanoseconds(clock, since: origin)))
    notifier.activate()
    for attempt in 1...ScreenSharingSourceIdleMonitor.maximumQuickResubmissions {
      await clock.waitForSleep(.milliseconds(500), count: 3 + attempt)
      clock.advance(by: .milliseconds(500))
      await resubmitted.wait(for: 1 + attempt)
    }
    await clock.waitForSleep(.seconds(2))
    clock.advance(by: .seconds(2))
    await resubmitted.wait(for: 2 + ScreenSharingSourceIdleMonitor.maximumQuickResubmissions)
    await clock.waitForSleep(.seconds(2), count: 2)
    #expect(notices == [2, 5] && !notifier.hasPendingNotice)
    monitor.recordEncoded(timestampNs: 8)
    clock.advance(by: .seconds(2))
    await attempted.wait(for: 5)
    #expect(notices == [2, 5, 8] && clock.pendingCount == 0)
    #expect(monitor.recordSubmission(timestampNs: 9, nowNs: nanoseconds(clock, since: origin)))
    notifier.activate()
    await clock.waitForSleep(.milliseconds(500), count: 4 + ScreenSharingSourceIdleMonitor.maximumQuickResubmissions)
    let pending = notifier.close()
    await pending?.value
    #expect(clock.pendingCount == 0)
    notifier.activate()
    notifier.flush()
    clock.advance(by: .seconds(5))
    #expect(notices == [2, 5, 8] && attempted.value == 5)
  }

  @Test func auditKeepsItsTargetThroughRecoveryUntilTheAnnouncedContentIsDecoded() {
    let audit = ScreenSharingDeliveryAudit()
    #expect(!audit.verify() && audit.recoveryFinished() == nil)
    audit.decoded(sourceTimestampNs: 10)
    audit.decoded(sourceTimestampNs: 9)
    #expect(audit.latestDecodedTimestampNs == 10)
    #expect(audit.noticed(latestTimestampNs: 10) && audit.noticed(latestTimestampNs: 9))
    #expect(audit.pendingTargetNs == nil)
    // Target 20 announced; recovery completes with a delayed older keyframe.
    #expect(!audit.noticed(latestTimestampNs: 20))
    #expect(audit.verify())
    #expect(!audit.verify())
    audit.decoded(sourceTimestampNs: 12)
    #expect(audit.recoveryFinished() == true)
    #expect(audit.pendingTargetNs == 20)
    audit.decoded(sourceTimestampNs: 21)
    #expect(audit.recoveryFinished() == false)
    #expect(audit.pendingTargetNs == nil && audit.recoveryFinished() == nil)
    // Content arriving during the grace period needs no recovery.
    #expect(!audit.noticed(latestTimestampNs: 30))
    audit.decoded(sourceTimestampNs: 30)
    #expect(!audit.verify() && audit.recoveryFinished() == nil)
    // A newer notice replaces the target; a retry checks it is still missing.
    #expect(!audit.noticed(latestTimestampNs: 40))
    #expect(!audit.noticed(latestTimestampNs: 41) && audit.pendingTargetNs == 41)
    #expect(audit.verify())
    #expect(audit.targetMissing())
    audit.decoded(sourceTimestampNs: 41)
    #expect(!audit.targetMissing())
    #expect(audit.pendingTargetNs == nil && audit.recoveryFinished() == nil && !audit.targetMissing())
  }

  @Test func retryDelaysGrowFromTheRefreshIntervalToACap() {
    let delays = (1...8).map { ScreenSharingDeliveryVerifier.retryDelay($0) }
    #expect(delays == [100, 200, 400, 800, 1600, 3200, 5000, 5000].map { Duration.milliseconds($0) })
    #expect(ScreenSharingDeliveryVerifier.retryDelay(0) == .milliseconds(100))
    #expect(ScreenSharingDeliveryVerifier.retryDelay(60) == .seconds(5))
  }

  @Test func auditRecordsWhenThePendingTargetIsFirstDecodedOnTheViewerClock() {
    let audit = ScreenSharingDeliveryAudit()
    audit.decoded(sourceTimestampNs: 10, nowNs: 100)
    #expect(audit.targetMetAtTimestampNs == nil)
    #expect(!audit.noticed(latestTimestampNs: 20))
    #expect(audit.verify())
    audit.decoded(sourceTimestampNs: 15, nowNs: 200)
    #expect(audit.targetMetAtTimestampNs == nil)
    audit.decoded(sourceTimestampNs: 20, nowNs: 300)
    audit.decoded(sourceTimestampNs: 21, nowNs: 400)
    #expect(audit.targetMetAtTimestampNs == 300)
    #expect(audit.recoveryFinished() == false)
    // A new notice starts a fresh measurement; content already present keeps
    // its first-decode time from the bounded ring.
    #expect(audit.noticed(latestTimestampNs: 21))
    #expect(audit.targetMetAtTimestampNs == 400)
    #expect(!audit.noticed(latestTimestampNs: 30))
    audit.decoded(sourceTimestampNs: 30, nowNs: 500)
    #expect(audit.targetMetAtTimestampNs == 500 && !audit.verify())
    // Content decoded before its notice keeps its first-decode time from the bounded ring.
    audit.decoded(sourceTimestampNs: 40, nowNs: 600)
    audit.decoded(sourceTimestampNs: 41, nowNs: 700)
    #expect(audit.noticed(latestTimestampNs: 40) && audit.targetMetAtTimestampNs == 600)
    #expect(audit.noticed(latestTimestampNs: 41) && audit.targetMetAtTimestampNs == 700)
    let ring = ScreenSharingDeliveryAudit()
    for index in 0..<(ScreenSharingDeliveryAudit.recentDecodeCapacity + 1) {
      ring.decoded(sourceTimestampNs: Int64(index + 1), nowNs: Int64(index + 1) * 10)
    }
    #expect(ring.noticed(latestTimestampNs: 1) && ring.targetMetAtTimestampNs == 20)
    #expect(ring.noticed(latestTimestampNs: 2) && ring.targetMetAtTimestampNs == 20)
  }

  @Test @MainActor func verifierRefreshesAfterGraceAndKeepsRetryingWithBackoffUntilTheContentArrives() async {
    let clock = TestClock()
    let audit = ScreenSharingDeliveryAudit()
    let settled = TestSignal()
    let refreshed = TestSignal()
    var outcomes: [ScreenSharingDeliveryVerifier.Outcome] = []
    let verifier = ScreenSharingDeliveryVerifier(
      audit: audit, grace: .milliseconds(500),
      refresh: { refreshed.signal() },
      report: {
        outcomes.append($0)
        settled.signal()
      },
      sleep: { try await clock.sleep(for: $0) })
    verifier.noticed(latestTimestampNs: 5)
    await clock.waitForSleep(.milliseconds(500))
    audit.decoded(sourceTimestampNs: 5)
    clock.advance(by: .milliseconds(500))
    await settled.wait(for: 1)
    #expect(outcomes == [.verifiedAfterGrace] && refreshed.value == 0)
    verifier.noticed(latestTimestampNs: 5)
    #expect(outcomes == [.verifiedAfterGrace, .verified])
    verifier.noticed(latestTimestampNs: 6)
    await clock.waitForSleep(.milliseconds(500), count: 2)
    // A newer notice replaces the pending one and restarts its grace period.
    verifier.noticed(latestTimestampNs: 20)
    await clock.waitForSleep(.milliseconds(500), count: 3)
    #expect(clock.pendingCount == 1)
    clock.advance(by: .milliseconds(500))
    await settled.wait(for: 3)
    #expect(outcomes.last == .refresh && refreshed.value == 1)
    // Recovery completes with a keyframe marked 10: the target 20 stays pending
    // and a retry follows the first backoff delay.
    audit.decoded(sourceTimestampNs: 10)
    verifier.recoveryChanged(.init(revision: 1, needed: true))
    verifier.recoveryChanged(.init(revision: 2, needed: false))
    #expect(outcomes.last == .retry && audit.pendingTargetNs == 20)
    verifier.recoveryChanged(.init(revision: 2, needed: false))
    await clock.waitForSleep(.milliseconds(100))
    #expect(refreshed.value == 1)
    clock.advance(by: .milliseconds(100))
    await refreshed.wait(for: 2)
    // An executed retry is reported distinctly from its scheduling.
    #expect(outcomes.suffix(2) == [.retry, .retryExecuted])
    // A second stale completion waits twice as long; content arriving during
    // the delay cancels the retry (scheduled, never executed).
    verifier.recoveryChanged(.init(revision: 3, needed: false))
    await clock.waitForSleep(.milliseconds(200))
    audit.decoded(sourceTimestampNs: 20)
    clock.advance(by: .milliseconds(200))
    await settled.wait(for: 7)
    #expect(outcomes.last == .recovered && refreshed.value == 2 && audit.pendingTargetNs == nil)
    #expect(outcomes.filter { $0 == .retryExecuted }.count == 1)
    verifier.recoveryChanged(.init(revision: 4, needed: false))
    #expect(outcomes.count == 7)
    // Retries never stop while the content is missing; the delay caps at 5 s.
    verifier.noticed(latestTimestampNs: 30)
    await clock.waitForSleep(.milliseconds(500), count: 4)
    clock.advance(by: .milliseconds(500))
    await refreshed.wait(for: 3)
    var revision: UInt64 = 5
    for retry in 1...9 {
      verifier.recoveryChanged(.init(revision: revision, needed: false))
      revision += 1
      let delay = ScreenSharingDeliveryVerifier.retryDelay(retry)
      await clock.waitForSleep(delay, count: retry >= 7 ? retry - 6 : 1)
      clock.advance(by: delay)
      await refreshed.wait(for: 3 + retry)
    }
    #expect(outcomes.filter { $0 == .retry }.count == 11 && audit.pendingTargetNs == 30)
    #expect(outcomes.filter { $0 == .retryExecuted }.count == 10)
    // Closing cancels a pending retry; nothing runs afterwards.
    verifier.recoveryChanged(.init(revision: revision, needed: false))
    await clock.waitForSleep(.seconds(5), count: 4)
    let pending = verifier.close()
    await pending?.value
    #expect(clock.pendingCount == 0)
    verifier.noticed(latestTimestampNs: 41)
    verifier.recoveryChanged(.init(revision: revision + 1, needed: false))
    clock.advance(by: .seconds(30))
    #expect(refreshed.value == 12)
  }

}
