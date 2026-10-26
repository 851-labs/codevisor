import Testing

@testable import ScreenSharing

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
    #expect(counters.keys.allSatisfy { !$0.lowercased().contains("drop") })
  }

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
    #expect(counters["captureSamplesWithoutImage"] == 1)
    #expect(Accounting.callbackTotal(counters: counters) == callbacks)
    #expect(Accounting.callbackTotal(counters: counters.merging(["capturedFrames": 900]) { a, _ in a }) == callbacks)
  }
}
