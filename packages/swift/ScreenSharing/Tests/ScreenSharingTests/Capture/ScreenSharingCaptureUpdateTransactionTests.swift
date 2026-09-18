#if os(macOS)
  import CodevisorTestSupport
  import Testing

  @testable import ScreenSharing

  /// Exercises the transaction called by ScreenSharingCapture.update. Only the
  /// SCK operation and generation observation are replaced; validation, await,
  /// stale-result rejection, stored request and metric writes are production code.
  @Suite @MainActor struct ScreenSharingCaptureUpdateTransactionTests {
    private enum Failure: Error { case streamUpdate }

    @MainActor private final class HeldApply {
      let entered = TestSignal()
      var request: ScreenSharingCaptureIntervalRequest?
      private var continuation: CheckedContinuation<Void, any Error>?

      func apply(_ request: ScreenSharingCaptureIntervalRequest) async throws {
        self.request = request
        try await withCheckedThrowingContinuation { continuation in
          self.continuation = continuation
          entered.signal()
        }
      }

      func finish() {
        let pending = continuation
        continuation = nil
        pending?.resume()
      }
    }

    @MainActor private final class Generation { var value = 0 }

    private func initialCapture() async throws -> (ScreenSharingCapture, ScreenSharingMetrics) {
      let capture = ScreenSharingCapture(captureIntervalFPS: 120)
      let metrics = ScreenSharingMetrics()
      try await capture.applyIntervalUpdate(
        configuration: .init(), override: 120, metrics: metrics,
        apply: { _ in }, isCurrent: { true })
      return (capture, metrics)
    }

    @Test func validationFailureNeverCallsTheStreamOrChangesTheRequest() async throws {
      let (capture, metrics) = try await initialCapture()
      let before = metrics.snapshot().labels
      var calls = 0
      await #expect(throws: ScreenSharingError.self) {
        try await capture.applyIntervalUpdate(
          configuration: .init(framesPerSecond: 60), override: 30, metrics: metrics,
          apply: { _ in calls += 1 }, isCurrent: { true })
      }
      #expect(calls == 0)
      #expect(capture.requestState.overrideFramesPerSecond == 120)
      #expect(metrics.snapshot().labels == before)
    }

    @Test func aThrownStreamUpdatePreservesTheOriginalErrorRequestAndLabels() async throws {
      let (capture, metrics) = try await initialCapture()
      let before = metrics.snapshot().labels
      var calls = 0
      var generationChecks = 0
      await #expect(throws: Failure.streamUpdate) {
        try await capture.applyIntervalUpdate(
          configuration: .init(framesPerSecond: 30), override: nil, metrics: metrics,
          apply: { request in
            calls += 1
            #expect(request.requestedFramesPerSecond == 30)
            throw Failure.streamUpdate
          },
          isCurrent: {
            generationChecks += 1; return true
          })
      }
      #expect(calls == 1 && generationChecks == 0)
      #expect(capture.requestState.overrideFramesPerSecond == 120)
      #expect(metrics.snapshot().labels == before)
    }

    @Test func aHeldSuccessfulUpdateCommitsOnlyAfterItsApplyReturns() async throws {
      let (capture, metrics) = try await initialCapture()
      let before = metrics.snapshot().labels
      let held = HeldApply()
      let update = Task { @MainActor in
        try await capture.applyIntervalUpdate(
          configuration: .init(framesPerSecond: 30), override: nil, metrics: metrics,
          apply: held.apply, isCurrent: { true })
      }
      await held.entered.wait()
      #expect(held.request?.requestedFramesPerSecond == 30)
      #expect(capture.requestState.overrideFramesPerSecond == 120)
      #expect(metrics.snapshot().labels == before)
      held.finish()
      try await update.value
      #expect(capture.requestState.overrideFramesPerSecond == nil)
      #expect(metrics.snapshot().labels["captureRequestedMinimumFrameIntervalFPS"] == "30")
      #expect(metrics.snapshot().labels["captureRequestedFrameIntervalOverride"] == "none")
    }

    @Test func aSuccessfulApplyFromAnOldGenerationCannotCommit() async throws {
      let (capture, metrics) = try await initialCapture()
      let before = metrics.snapshot().labels
      let held = HeldApply()
      let generation = Generation()
      let startedGeneration = generation.value
      let update = Task { @MainActor in
        try await capture.applyIntervalUpdate(
          configuration: .init(framesPerSecond: 30), override: nil, metrics: metrics,
          apply: held.apply, isCurrent: { generation.value == startedGeneration })
      }
      await held.entered.wait()
      generation.value += 1
      held.finish()
      await #expect(throws: CancellationError.self) { try await update.value }
      #expect(capture.requestState.overrideFramesPerSecond == 120)
      #expect(metrics.snapshot().labels == before)
    }
  }
#endif
