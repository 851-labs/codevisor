import Testing
import CodevisorTestSupport

import ScreenSharing
@testable import ScreenSharingDiagnostics

@Suite struct ScreenSharingFirstDrawGateTests {
  @Test @MainActor func signalResumesAPendingWaitOnce() async throws {
    let clock = TestClock()
    let gate = ScreenSharingFirstDrawGate()
    let waiting = TestSignal()
    let waiter = Task { @MainActor in
      waiting.signal()
      try await gate.wait(timeout: .seconds(10)) { try await clock.sleep(for: $0) }
    }
    await waiting.wait()
    await clock.waitForSleep(.seconds(10))
    gate.signal()
    try await waiter.value
    #expect(gate.isSignalled && gate.failure == nil && gate.resumeCount == 1)
    #expect(clock.pendingCount == 0)  // the deadline was cancelled on exit
    // A later wait returns immediately; a repeated signal is harmless.
    gate.signal()
    try await gate.wait(timeout: .seconds(1)) { try await clock.sleep(for: $0) }
    #expect(gate.resumeCount == 1)
  }

  /// Ordering check (added while diagnosing the 11:18 UTC stalled suite run; NOT a reproduction of it):
  /// the signal is issued before the waiter's task gets its first main-actor turn, so no continuation
  /// exists yet. The main-actor-isolated gate must observe the signal on entry and return without ever
  /// registering a continuation that nobody resumes.
  @Test @MainActor func signalBeforeTheWaiterRegistersIsObservedOnEntry() async throws {
    let clock = TestClock()
    let gate = ScreenSharingFirstDrawGate()
    let waiter = Task { @MainActor in
      try await gate.wait(timeout: .seconds(10)) { try await clock.sleep(for: $0) }
    }
    gate.signal()  // same main-actor turn as the task creation: the waiter has not run yet
    try await waiter.value
    #expect(gate.isSignalled && gate.failure == nil)
    #expect(gate.resumeCount == 0)  // nothing was pending: the wait returned on entry, no continuation was ever stored
    #expect(clock.pendingCount == 0 && clock.requestCount(.seconds(10)) == 0)  // no deadline was even started
  }

  @Test @MainActor func timeoutFailsThePendingWaitOnceAndBlocksLaterWaits() async {
    let clock = TestClock()
    let gate = ScreenSharingFirstDrawGate()
    let waiter = Task { @MainActor in
      try await gate.wait(timeout: .seconds(10)) { try await clock.sleep(for: $0) }
    }
    await clock.waitForSleep(.seconds(10))
    clock.advance(by: .seconds(10))
    await #expect(throws: ScreenSharingFirstDrawGate.Failure.timedOut) { try await waiter.value }
    #expect(gate.failure == .timedOut && gate.resumeCount == 1)
    gate.signal()  // a late first draw cannot revive readiness
    #expect(!gate.isSignalled)
    await #expect(throws: ScreenSharingFirstDrawGate.Failure.timedOut) {
      try await gate.wait(timeout: .seconds(1)) { try await clock.sleep(for: $0) }
    }
  }

  @Test @MainActor func cancellationResumesThePendingWaitOnceAndCancelsTheDeadline() async {
    let clock = TestClock()
    let gate = ScreenSharingFirstDrawGate()
    let waiter = Task { @MainActor in
      try await gate.wait(timeout: .seconds(10)) { try await clock.sleep(for: $0) }
    }
    await clock.waitForSleep(.seconds(10))
    waiter.cancel()
    await #expect(throws: ScreenSharingFirstDrawGate.Failure.cancelled) { try await waiter.value }
    #expect(gate.failure == .cancelled && gate.resumeCount == 1)
    #expect(clock.pendingCount == 0)
    await #expect(throws: ScreenSharingFirstDrawGate.Failure.cancelled) {
      try await gate.wait(timeout: .seconds(1)) { try await clock.sleep(for: $0) }
    }
  }
}

@Suite struct ScreenSharingFirstDrawGateTeardownTests {
  @Test @MainActor func teardownResolvesAHeldWaitOnceWithoutTaskCancellationAndBlocksLaterWaits() async {
    let clock = TestClock()
    let gate = ScreenSharingFirstDrawGate()
    let waiter = Task { @MainActor in
      try await gate.wait(timeout: .seconds(10)) { try await clock.sleep(for: $0) }
    }
    await clock.waitForSleep(.seconds(10))
    gate.teardown()
    await #expect(throws: ScreenSharingFirstDrawGate.Failure.tornDown) { try await waiter.value }
    #expect(gate.failure == .tornDown && gate.resumeCount == 1 && clock.pendingCount == 0)
    gate.signal()
    #expect(!gate.isSignalled)
    gate.teardown()  // idempotent
    await #expect(throws: ScreenSharingFirstDrawGate.Failure.tornDown) {
      try await gate.wait(timeout: .seconds(1)) { try await clock.sleep(for: $0) }
    }
    #expect(gate.resumeCount == 1)
  }
}

@Suite struct ScreenSharingOwnedWindowSessionTests {
  typealias Session = ScreenSharingOwnedWindowSession
  struct Boom: Error {}

  @MainActor
  final class Fake {
    var shown = 0
    var hidden = 0
    var captureStarts = 0
    var stops = 0
    var stopThrows = false
    var tick: Int64 = 0
    lazy var session = Session(
      show: { self.shown += 1 }, hide: { self.hidden += 1 },
      stopCapture: {
        self.stops += 1
        if self.stopThrows { throw Boom() }
      },
      now: {
        self.tick += 1
        return self.tick
      })
  }

  @Test @MainActor func normalPathClosesInOrderAfterASuccessfulStop() async throws {
    let fake = Fake()
    try await fake.session.start(ready: {}, startCapture: { fake.captureStarts += 1 })
    #expect(fake.session.lifecycle.state == .capturing && fake.shown == 1 && fake.captureStarts == 1)
    try fake.session.pauseWorkload {}
    #expect(await fake.session.stopCapture())
    #expect(fake.stops == 1 && fake.session.finish() == .closedAfterCaptureStop)
    #expect(fake.session.completedInOrder && fake.hidden == 1 && fake.session.stopSucceeded == true)
    #expect(fake.session.finish() == .closedAfterCaptureStop && fake.hidden == 1)  // idempotent
  }

  @Test @MainActor func cancellationWhileReadinessIsHeldAbandonsTheShownWindowAndNeverStartsCapture() async {
    let fake = Fake()
    let held = TestSignal()
    let entered = TestSignal()
    let task = Task { @MainActor in
      try await fake.session.start(
        ready: {
          entered.signal()
          // Readiness returns NORMALLY after the cancellation: only the
          // session's own check may prevent the capture start.
          await held.wait()
        },
        startCapture: { fake.captureStarts += 1 })
    }
    await entered.wait()
    task.cancel()
    held.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(fake.captureStarts == 0 && fake.stops == 0)
    #expect(fake.session.lifecycle.state == .abandoned && fake.session.lifecycle.abandonedFrom == .shown)
    #expect(fake.hidden == 1 && !fake.session.completedInOrder)
    #expect(
      fake.session.lifecycle.timestampsNs[.ready] == nil && fake.session.lifecycle.timestampsNs[.stopCapture] == nil)
    #expect(fake.session.startFailure != nil)
  }

  @Test @MainActor func cancellationAfterAHeldCaptureStartSucceededStopsTheStreamBeforeHiding() async {
    let fake = Fake()
    let held = TestSignal()
    let entered = TestSignal()
    let task = Task { @MainActor in
      try await fake.session.start(
        ready: {},
        startCapture: {
          entered.signal()
          await held.wait()  // the stream start completes after the cancellation
          fake.captureStarts += 1
        })
    }
    await entered.wait()
    task.cancel()
    held.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    // The stream had started, so it was really stopped before the window hid.
    #expect(fake.captureStarts == 1 && fake.stops == 1 && fake.hidden == 1)
    #expect(fake.session.stopSucceeded == true && fake.session.lifecycle.state == .closed)
    let stamps = fake.session.lifecycle.timestampsNs
    #expect(stamps[.startCapture]! < stamps[.stopCapture]! && stamps[.stopCapture]! <= stamps[.close]!)
    #expect(fake.session.startFailure?.contains("Cancellation") == true)
  }

  @Test @MainActor func cancellationAfterAHeldCaptureStartWithAFailingStopIsAbandonedNotClosed() async {
    let fake = Fake()
    fake.stopThrows = true
    let held = TestSignal()
    let entered = TestSignal()
    let task = Task { @MainActor in
      try await fake.session.start(
        ready: {},
        startCapture: {
          entered.signal(); await held.wait()
        })
    }
    await entered.wait()
    task.cancel()
    held.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(fake.stops == 1 && fake.hidden == 1)
    #expect(fake.session.stopSucceeded == false && fake.session.stopFailure != nil)
    #expect(fake.session.lifecycle.abandonedFrom == .capturing && !fake.session.completedInOrder)
    #expect((fake.session.record["cleanup"] as? String)?.hasPrefix("abandoned") == true)
    #expect(fake.session.record["stopSucceeded"] as? String == "false")
  }

  @Test @MainActor func failedCaptureStartAbandonsFromReadyWithoutAStopClaim() async {
    let fake = Fake()
    await #expect(throws: Boom.self) {
      try await fake.session.start(
        ready: {},
        startCapture: {
          fake.captureStarts += 1; throw Boom()
        })
    }
    #expect(fake.captureStarts == 1 && fake.hidden == 1 && fake.stops == 0)
    #expect(fake.session.lifecycle.abandonedFrom == .ready && fake.session.stopSucceeded == nil)
    #expect(!fake.session.completedInOrder)
    // finish() is idempotent: it keeps the first outcome and never hides twice.
    #expect(fake.session.finish() == .abandoned(from: .ready) && fake.hidden == 1)
    #expect(await fake.session.stopCapture() == false && fake.stops == 0)
  }

  @Test @MainActor func failedStreamStopIsPreservedAndNeverBecomesAnInOrderClose() async throws {
    let fake = Fake()
    fake.stopThrows = true
    try await fake.session.start(ready: {}, startCapture: { fake.captureStarts += 1 })
    #expect(await fake.session.stopCapture() == false && fake.stops == 1)
    #expect(fake.session.stopSucceeded == false && fake.session.stopFailure != nil)
    #expect(fake.session.lifecycle.state == .capturing)  // no stopCapture transition was applied
    #expect(fake.session.finish() == .abandoned(from: .capturing))
    #expect(!fake.session.completedInOrder && fake.hidden == 1)
    #expect(fake.session.record["stopSucceeded"] as? String == "false")
  }

  @Test @MainActor func repeatedCleanupAfterAFailedStopNeverReplacesTheFailure() async throws {
    // The runtime path: normal-end stop fails → run throws → stop() asks the
    // session to stop again. The second closure would succeed trivially (the
    // capture already cleared its stream); it must not run or be believed.
    let fake = Fake()
    fake.stopThrows = true
    try await fake.session.start(ready: {}, startCapture: { fake.captureStarts += 1 })
    #expect(await fake.session.stopCapture() == false && fake.stops == 1)
    fake.stopThrows = false
    #expect(await fake.session.stopCapture() == false)
    #expect(fake.stops == 1 && fake.session.stopRetriesRefused == 1)
    #expect(fake.session.stopSucceeded == false && fake.session.stopFailure != nil)
    #expect(fake.session.lifecycle.state == .capturing)
    #expect(fake.session.finish() == .abandoned(from: .capturing))
    #expect(!fake.session.completedInOrder && fake.hidden == 1)
    // Cleanup again (top-level catch after a failed run): unchanged evidence.
    #expect(await fake.session.stopCapture() == false && fake.stops == 1)
    #expect(fake.session.finish() == .abandoned(from: .capturing) && fake.hidden == 1)
    let record = fake.session.record
    #expect(record["stopSucceeded"] as? String == "false" && record["stopRetriesRefused"] as? Int == 1)
    #expect(
      (record["cleanup"] as? String)?.hasPrefix("abandoned") == true && record["completedInOrder"] as? Bool == false)
  }

  @Test @MainActor func failureBeforeTheWindowIsShownNeedsNoCleanup() async {
    let broken = Session(show: { throw Boom() }, hide: {}, stopCapture: {})
    await #expect(throws: Boom.self) { try await broken.start(ready: {}, startCapture: {}) }
    #expect(broken.lifecycle.state == .abandoned && broken.lifecycle.abandonedFrom == .shown && broken.hideCount == 1)
    let never = Session(show: {}, hide: {}, stopCapture: {})
    #expect(never.finish() == .neverShown && never.hideCount == 0)
  }
}
