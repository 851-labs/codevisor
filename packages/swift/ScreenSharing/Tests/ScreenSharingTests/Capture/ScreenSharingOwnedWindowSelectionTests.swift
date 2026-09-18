import Testing

@testable import ScreenSharing

@Suite struct ScreenSharingOwnedWindowSelectionTests {
  typealias Selection = ScreenSharingOwnedWindowSelection

  @Test func selectsOnlyTheExactWindowOwnedByThisProcess() {
    let candidates = [
      Selection.Candidate(windowID: 10, owningProcessID: 500), Selection.Candidate(windowID: 11, owningProcessID: 500),
      Selection.Candidate(windowID: 12, owningProcessID: 777),
    ]
    #expect(Selection.select(windowID: 11, processID: 500, from: candidates) == .success(candidates[1]))
    #expect(
      Selection.select(windowID: 12, processID: 500, from: candidates)
        == .failure(.owningProcessMismatch(reported: 777)))
    #expect(Selection.select(windowID: 99, processID: 500, from: candidates) == .failure(.windowNotListed))
    #expect(Selection.select(windowID: 10, processID: 500, from: []) == .failure(.windowNotListed))
  }

  @Test func refusesUnreportedOwnerAndDuplicateListings() {
    let unreported = [Selection.Candidate(windowID: 10, owningProcessID: nil)]
    #expect(Selection.select(windowID: 10, processID: 500, from: unreported) == .failure(.owningProcessNotReported))
    let duplicated = [
      Selection.Candidate(windowID: 10, owningProcessID: 500), Selection.Candidate(windowID: 10, owningProcessID: 500),
    ]
    #expect(Selection.select(windowID: 10, processID: 500, from: duplicated) == .failure(.ambiguous(count: 2)))
  }
}

@Suite struct ScreenSharingCaptureCallbackAccountingTests {
  typealias Accounting = ScreenSharingCaptureCallbackAccounting

  @Test func onlyCompleteSamplesWithAnImageAreDelivered() {
    let metrics = ScreenSharingMetrics()
    #expect(Accounting.record(valid: true, rawStatus: 0, hasImage: true, metrics: metrics))
    #expect(!Accounting.record(valid: true, rawStatus: 0, hasImage: false, metrics: metrics))
    for status in [1, 2, 3, 4, 5] {
      #expect(!Accounting.record(valid: true, rawStatus: status, hasImage: true, metrics: metrics))
    }
    #expect(!Accounting.record(valid: false, rawStatus: 0, hasImage: true, metrics: metrics))
    #expect(!Accounting.record(valid: true, rawStatus: nil, hasImage: true, metrics: metrics))
    #expect(!Accounting.record(valid: true, rawStatus: 42, hasImage: true, metrics: metrics))
    let counters = metrics.snapshot().counters
    #expect(counters["captureCallbacksComplete"] == 2)
    #expect(counters["captureSamplesWithoutImage"] == 1)
    #expect(counters["captureCallbacksIdle"] == 1 && counters["captureCallbacksBlank"] == 1)
    #expect(counters["captureCallbacksSuspended"] == 1 && counters["captureCallbacksStarted"] == 1)
    #expect(counters["captureCallbacksStopped"] == 1)
    #expect(counters["captureSamplesInvalid"] == 1 && counters["captureSamplesWithoutStatus"] == 1)
    #expect(counters["captureCallbacksOtherStatus"] == 1)
    #expect(metrics.snapshot().labels["captureLatestStatus"] == "other(42)")
    // No counter name mentions a pool drop: absence of callbacks is not measured here.
    #expect(counters.keys.allSatisfy { !$0.lowercased().contains("drop") })
  }

  /// The total is what a report divides by, so it has to be the number of callbacks that actually
  /// happened: every bucket counted once, and the missing-image sub-count of complete callbacks not
  /// counted a second time.
  @Test func theCallbackTotalCountsEachCallbackExactlyOnce() {
    let metrics = ScreenSharingMetrics()
    #expect(Accounting.callbackTotal(counters: [:]) == 0)
    var callbacks = 0
    for (status, hasImage) in [
      (0, true), (0, false), (1, true), (2, true), (3, true), (4, true), (5, true), (99, true),
    ] {
      Accounting.record(valid: true, rawStatus: status, hasImage: hasImage, metrics: metrics)
      callbacks += 1
    }
    Accounting.record(valid: false, rawStatus: 0, hasImage: true, metrics: metrics)
    Accounting.record(valid: true, rawStatus: nil, hasImage: true, metrics: metrics)
    callbacks += 2
    let counters = metrics.snapshot().counters
    #expect(counters["captureSamplesWithoutImage"] == 1)  // a complete callback that carried no image
    #expect(Accounting.callbackTotal(counters: counters) == callbacks)
    // Counters this accounting never writes cannot inflate the total.
    #expect(Accounting.callbackTotal(counters: counters.merging(["capturedFrames": 900]) { a, _ in a }) == callbacks)
  }
}

@Suite struct ScreenSharingOwnedWorkloadLifecycleTests {
  typealias Lifecycle = ScreenSharingOwnedWorkloadLifecycle

  @Test func boundariesMustHappenInOrderAndCaptureStopsBeforeTheWindowCloses() throws {
    var lifecycle = Lifecycle()
    #expect(lifecycle.state == .created)
    #expect(throws: Lifecycle.Refusal(transition: .startCapture, state: .created)) {
      try lifecycle.apply(.startCapture, atNs: 1)
    }
    try lifecycle.apply(.show, atNs: 1)
    #expect(throws: Lifecycle.Refusal(transition: .pauseWorkload, state: .shown)) {
      try lifecycle.apply(.pauseWorkload, atNs: 2)
    }
    try lifecycle.apply(.ready, atNs: 2)
    try lifecycle.apply(.startCapture, atNs: 3)
    #expect(throws: Lifecycle.Refusal(transition: .close, state: .capturing)) { try lifecycle.apply(.close, atNs: 4) }
    try lifecycle.apply(.pauseWorkload, atNs: 4)
    #expect(throws: Lifecycle.Refusal(transition: .pauseWorkload, state: .workloadPaused)) {
      try lifecycle.apply(.pauseWorkload, atNs: 5)
    }
    #expect(!lifecycle.completedInOrder)
    try lifecycle.apply(.stopCapture, atNs: 5)
    #expect(throws: Lifecycle.Refusal(transition: .stopCapture, state: .captureStopped)) {
      try lifecycle.apply(.stopCapture, atNs: 6)
    }
    try lifecycle.apply(.close, atNs: 6)
    #expect(lifecycle.state == .closed && lifecycle.completedInOrder)
    #expect(
      lifecycle.timestampsNs == [.show: 1, .ready: 2, .startCapture: 3, .pauseWorkload: 4, .stopCapture: 5, .close: 6])
  }

  @Test func captureMayStopWithoutAPauseAndTheWindowNeverClosesFirst() throws {
    var lifecycle = Lifecycle()
    try lifecycle.apply(.show, atNs: 1); try lifecycle.apply(.ready, atNs: 2);
    try lifecycle.apply(.startCapture, atNs: 3)
    try lifecycle.apply(.stopCapture, atNs: 4)
    try lifecycle.apply(.close, atNs: 4)
    #expect(lifecycle.completedInOrder)
    var early = Lifecycle()
    try early.apply(.show, atNs: 1); try early.apply(.ready, atNs: 2)
    #expect(throws: Lifecycle.Refusal(transition: .close, state: .ready)) { try early.apply(.close, atNs: 3) }
  }

  @Test func cleanupBeforeReadinessOrAfterAFailedStartAbandonsTheWindowWithoutClaimingAStop() throws {
    // Shown, readiness never reached (no first draw / not visible).
    var shown = Lifecycle()
    try shown.apply(.show, atNs: 1)
    #expect(shown.cleanUp(captureStopCompleted: false, atNs: 2) == .abandoned(from: .shown))
    #expect(shown.state == .abandoned && shown.abandonedFrom == .shown && !shown.completedInOrder)
    #expect(shown.timestampsNs[.stopCapture] == nil && shown.timestampsNs[.close] == nil)
    // Ready, then SCStream start / ownership selection failed: captureStarted
    // was never applied. Even a stray "stop completed" claim cannot fabricate
    // a capture stop from this state.
    var failedStart = Lifecycle()
    try failedStart.apply(.show, atNs: 1); try failedStart.apply(.ready, atNs: 2)
    #expect(failedStart.cleanUp(captureStopCompleted: true, atNs: 3) == .abandoned(from: .ready))
    #expect(failedStart.timestampsNs[.stopCapture] == nil && !failedStart.completedInOrder)
    // Nothing shown: nothing to clean.
    var never = Lifecycle()
    #expect(never.cleanUp(captureStopCompleted: false, atNs: 1) == .neverShown)
    #expect(never.state == .created)
  }

  @Test func cleanupDuringAnActiveRunCreditsTheStopOnlyWithCompletionEvidence() throws {
    // Error mid-run, stream stop completed (capture recorded completion).
    var stopped = Lifecycle()
    try stopped.apply(.show, atNs: 1); try stopped.apply(.ready, atNs: 2); try stopped.apply(.startCapture, atNs: 3)
    #expect(stopped.cleanUp(captureStopCompleted: true, atNs: 4) == .closedAfterCaptureStop)
    #expect(stopped.state == .closed && stopped.completedInOrder)
    #expect(stopped.timestampsNs[.stopCapture] == 4 && stopped.timestampsNs[.close] == 4)
    // Error mid-run, stop did not complete: abandoned from capturing, no stop claimed.
    var unstopped = Lifecycle()
    try unstopped.apply(.show, atNs: 1); try unstopped.apply(.ready, atNs: 2);
    try unstopped.apply(.startCapture, atNs: 3)
    #expect(unstopped.cleanUp(captureStopCompleted: false, atNs: 4) == .abandoned(from: .capturing))
    #expect(unstopped.timestampsNs[.stopCapture] == nil && !unstopped.completedInOrder)
    // Paused workload, stop completed: closes in order.
    var paused = Lifecycle()
    try paused.apply(.show, atNs: 1); try paused.apply(.ready, atNs: 2); try paused.apply(.startCapture, atNs: 3)
    try paused.apply(.pauseWorkload, atNs: 4)
    #expect(paused.cleanUp(captureStopCompleted: true, atNs: 5) == .closedAfterCaptureStop)
    #expect(paused.completedInOrder)
    // Already stopped by the normal path, then cleanup: closes; a second cleanup is a no-op.
    var normal = Lifecycle()
    try normal.apply(.show, atNs: 1); try normal.apply(.ready, atNs: 2); try normal.apply(.startCapture, atNs: 3)
    try normal.apply(.stopCapture, atNs: 4)
    #expect(normal.cleanUp(captureStopCompleted: true, atNs: 5) == .closedAfterCaptureStop)
    #expect(normal.cleanUp(captureStopCompleted: true, atNs: 6) == .alreadyFinished(.closed))
    #expect(throws: Lifecycle.Refusal(transition: .close, state: .abandoned)) { try unstopped.apply(.close, atNs: 7) }
    var fresh = Lifecycle()
    #expect(throws: Lifecycle.Refusal(transition: .abandon, state: .created)) { try fresh.apply(.abandon, atNs: 1) }
  }
}
