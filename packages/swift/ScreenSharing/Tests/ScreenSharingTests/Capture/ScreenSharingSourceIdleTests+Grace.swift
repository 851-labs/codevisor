import CodevisorTestSupport
import Foundation
import Testing
@testable import ScreenSharing

extension ScreenSharingSourceIdleTests {
  @Test func monitorSlowPhaseNeverReoffersFasterThanTheThreshold() {
    let monitor = ScreenSharingSourceIdleMonitor(thresholdNs: 3_000_000_000, slowIntervalNs: 2_000_000_000)
    #expect(monitor.slowResubmissionIntervalNs == 3_000_000_000)
    #expect(monitor.recordSubmission(timestampNs: 1, nowNs: 0))
    var now: Int64 = 0
    for _ in 0..<ScreenSharingSourceIdleMonitor.maximumQuickResubmissions {
      now += 3_000_000_000
      #expect(monitor.evaluate(nowNs: now) == .resubmit)
    }
    #expect(monitor.evaluate(nowNs: now + 2_000_000_000) == .wait(untilNs: now + 3_000_000_000))
    #expect(ScreenSharingSourceIdleMonitor(thresholdNs: 500, slowIntervalNs: 2_000).slowResubmissionIntervalNs == 2_000)
  }

  @Test @MainActor func progressAwareGraceExtendsOnlyWhileNewerContentArrivesAndIsCapped() async {
    let clock = TestClock()
    let audit = ScreenSharingDeliveryAudit()
    let settled = TestSignal()
    var outcomes: [ScreenSharingDeliveryVerifier.Outcome] = []
    let verifier = ScreenSharingDeliveryVerifier(
      audit: audit, grace: .milliseconds(100), graceExtensions: 2,
      refresh: {},
      report: {
        outcomes.append($0)
        settled.signal()
      },
      sleep: { try await clock.sleep(for: $0) })
    audit.decoded(sourceTimestampNs: 10)
    // Progress: strictly newer content short of the target extends the wait.
    verifier.noticed(latestTimestampNs: 50)
    await clock.waitForSleep(.milliseconds(100))
    audit.decoded(sourceTimestampNs: 20)
    clock.advance(by: .milliseconds(100))
    await settled.wait(for: 1)
    #expect(outcomes == [.graceExtended])
    await clock.waitForSleep(.milliseconds(100), count: 2)
    // Duplicates and older frames are not progress.
    audit.decoded(sourceTimestampNs: 20)
    audit.decoded(sourceTimestampNs: 15)
    clock.advance(by: .milliseconds(100))
    await settled.wait(for: 2)
    #expect(outcomes == [.graceExtended, .refresh] && audit.pendingTargetNs == 50)
    // The target arriving during an extension verifies without a refresh.
    audit.decoded(sourceTimestampNs: 50)
    verifier.noticed(latestTimestampNs: 80)
    await clock.waitForSleep(.milliseconds(100), count: 3)
    audit.decoded(sourceTimestampNs: 60)
    clock.advance(by: .milliseconds(100))
    await settled.wait(for: 3)
    #expect(outcomes.last == .graceExtended)
    await clock.waitForSleep(.milliseconds(100), count: 4)
    audit.decoded(sourceTimestampNs: 80)
    clock.advance(by: .milliseconds(100))
    await settled.wait(for: 4)
    #expect(outcomes.last == .verifiedAfterGrace && audit.pendingTargetNs == nil)
    // The cap bounds the extension: two windows, then refresh despite progress.
    verifier.noticed(latestTimestampNs: 200)
    for (index, identity) in [90, 100, 110].enumerated() {
      await clock.waitForSleep(.milliseconds(100), count: index + 5)
      audit.decoded(sourceTimestampNs: Int64(identity))
      clock.advance(by: .milliseconds(100))
      await settled.wait(for: index + 5)
    }
    #expect(outcomes.suffix(3) == [.graceExtended, .graceExtended, .refresh] && audit.pendingTargetNs == 200)
    // A newer notice replaces an extended wait; closing cancels it.
    audit.decoded(sourceTimestampNs: 200)
    verifier.recoveryChanged(.init(revision: 1, needed: false))
    #expect(outcomes.last == .recovered)
    verifier.noticed(latestTimestampNs: 300)
    await clock.waitForSleep(.milliseconds(100), count: 8)
    audit.decoded(sourceTimestampNs: 210)
    clock.advance(by: .milliseconds(100))
    await settled.wait(for: 9)
    // The report precedes registration of the extended sleep. Wait for that
    // registration before cancelling it, so the replacement is sleep ten.
    await clock.waitForSleep(.milliseconds(100), count: 9)
    verifier.noticed(latestTimestampNs: 310)
    await clock.waitForSleep(.milliseconds(100), count: 10)
    #expect(clock.pendingCount == 1)
    let pending = verifier.close()
    await pending?.value
    #expect(clock.pendingCount == 0 && outcomes.count == 9)
  }

  @Test @MainActor func promotedDefaultsAnnounceAt100msAndExtendA100msGraceAtMostFourTimes() async {
    #expect(ScreenSharingSourceIdleMonitor.defaultThresholdNs == 100_000_000)
    #expect(ScreenSharingSourceIdleMonitor.legacyThresholdNs == 500_000_000)
    #expect(ScreenSharingDeliveryVerifier.defaultGrace == .milliseconds(100))
    #expect(ScreenSharingDeliveryVerifier.defaultGraceExtensions == 4)
    #expect(ScreenSharingDeliveryVerifier.legacyGrace == .milliseconds(500))
    #expect(ScreenSharingDeliveryVerifier.legacyGraceExtensions == 0)
    let monitor = ScreenSharingSourceIdleMonitor()
    #expect(monitor.recordSubmission(timestampNs: 1, nowNs: 0))
    monitor.recordEncoded(timestampNs: 1)
    #expect(monitor.evaluate(nowNs: 99_999_999) == .wait(untilNs: 100_000_000))
    #expect(monitor.evaluate(nowNs: 100_000_000) == .idle(latestEncodedNs: 1))
    let clock = TestClock()
    let audit = ScreenSharingDeliveryAudit()
    let settled = TestSignal()
    var outcomes: [ScreenSharingDeliveryVerifier.Outcome] = []
    let verifier = ScreenSharingDeliveryVerifier(
      audit: audit, refresh: {},
      report: {
        outcomes.append($0)
        settled.signal()
      },
      sleep: { try await clock.sleep(for: $0) })
    verifier.noticed(latestTimestampNs: 100)
    // Progressing content extends four times (500 ms after the notice), then refreshes.
    for window in 1...5 {
      await clock.waitForSleep(.milliseconds(100), count: window)
      audit.decoded(sourceTimestampNs: Int64(window * 10))
      clock.advance(by: .milliseconds(100))
      await settled.wait(for: window)
    }
    #expect(outcomes == Array(repeating: .graceExtended, count: 4) + [.refresh])
    // The former defaults remain available as explicit overrides.
    let legacy = ScreenSharingDeliveryVerifier(
      audit: ScreenSharingDeliveryAudit(), grace: ScreenSharingDeliveryVerifier.legacyGrace,
      graceExtensions: ScreenSharingDeliveryVerifier.legacyGraceExtensions, refresh: {}, report: { _ in },
      sleep: { try await clock.sleep(for: $0) })
    legacy.noticed(latestTimestampNs: 5)
    await clock.waitForSleep(.milliseconds(500))
    #expect(clock.pendingCount == 1)
    let pending = [verifier.close(), legacy.close()].compactMap { $0 }
    for task in pending { await task.value }
    #expect(clock.pendingCount == 0)
  }

  @Test func boundaryTracingIsOptInAndNeverEvaluatesEntriesWhenDisabled() {
    let metrics = ScreenSharingMetrics()
    var evaluated = 0
    func entry() -> String {
      evaluated += 1
      return "event"
    }
    metrics.trace("boundary", entry())
    #expect(evaluated == 0 && metrics.snapshot().traces == nil)
    metrics.enableTracing()
    for _ in 0..<70 { metrics.trace("boundary", entry()) }
    #expect(evaluated == 70)
    #expect(metrics.snapshot().traces?["boundary"]?.count == 64)
  }

  @Test func shortfallRequestDoesNotInvalidateAPendingRecovery() {
    let signal = ScreenSharingRefreshSignal()
    let metrics = ScreenSharingMetrics()
    signal.onChange { event in metrics.increment(event.needed ? "requested" : "recovered") }
    signal.request()
    let generation = signal.keyframeGeneration
    #expect(!signal.requestUnlessPending())
    #expect(signal.keyframeGeneration == generation)
    signal.decodedKeyframe(generation: generation)
    #expect(metrics.snapshot().counters["recovered"] == 1)
    #expect(signal.requestUnlessPending())
    #expect(signal.keyframeGeneration == generation + 1)
    #expect(metrics.snapshot().counters["requested"] == 2)
    signal.close()
    #expect(!signal.requestUnlessPending())
  }
}
