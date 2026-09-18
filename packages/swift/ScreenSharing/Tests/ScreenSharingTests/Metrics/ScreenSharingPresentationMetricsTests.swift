import Testing
@testable import ScreenSharing

struct ScreenSharingPresentationMetricsTests {
  @Test func skippedDrawablesAndRedrawsDoNotCountAsNewPresentedFrames() {
    let metrics = ScreenSharingMetrics()
    #expect(!metrics.recordPresentation(isNewFrame: true, presentedAt: 0, submittedAt: 1, receivedAt: 0.5))
    #expect(!metrics.recordPresentation(isNewFrame: false, presentedAt: 2, submittedAt: 1, receivedAt: 0.5))
    #expect(metrics.recordPresentation(isNewFrame: true, presentedAt: 2, submittedAt: 1.75, receivedAt: 1.5))
    let result = metrics.snapshot()
    #expect(result.counters["presentationCallbacks"] == 2)
    #expect(result.counters["unpresentedDrawables"] == 1)
    #expect(result.counters["presentedFrames"] == 1)
    #expect(result.timings["submissionToPresentation"]?.p50Ms == 250)
    #expect(result.timings["receiverCallbackToPresentation"]?.p50Ms == 500)
  }

  /// CoreAnimation's presentation time can land before the submission this
  /// process timed, and a negative latency is not a measurement. The frame was
  /// still on screen, so it counts; only the impossible interval is dropped.
  @Test func aPresentationTimeBeforeSubmissionCountsTheFrameAndDiscardsTheInterval() {
    let metrics = ScreenSharingMetrics()
    #expect(metrics.recordPresentation(isNewFrame: true, presentedAt: 1, submittedAt: 2, receivedAt: 0.5))
    let result = metrics.snapshot()
    #expect(result.counters["presentedFrames"] == 1)
    #expect(result.timings["submissionToPresentation"] == nil, "a negative latency would poison the percentiles")
    #expect(result.timings["receiverCallbackToPresentation"]?.count == 1)
    #expect(result.timings["receiverCallbackToPresentation"]?.p50Ms == 500)
  }

  @Test(arguments: [Double.nan, .infinity, -.infinity, -1, -0.0, 0])
  func aTimeThatCannotBeAPresentationIsAnUnpresentedDrawable(presentedAt: Double) {
    let metrics = ScreenSharingMetrics()
    #expect(!metrics.recordPresentation(isNewFrame: true, presentedAt: presentedAt, submittedAt: 1, receivedAt: 0.5))
    let result = metrics.snapshot()
    #expect(result.counters["presentationCallbacks"] == 1)
    #expect(result.counters["unpresentedDrawables"] == 1)
    #expect(result.counters["presentedFrames"] == nil)
    #expect(result.timings.isEmpty, "an unpresented drawable has no latency to report")
  }

  /// A redraw of the cached frame reaches the same handler. It is not a
  /// callback the renderer owes a frame for, so nothing at all is counted.
  @Test func aRedrawLeavesTheAccountingUntouched() {
    let metrics = ScreenSharingMetrics()
    #expect(!metrics.recordPresentation(isNewFrame: false, presentedAt: 2, submittedAt: 1, receivedAt: 0.5))
    let result = metrics.snapshot()
    #expect(result.counters.isEmpty)
    #expect(result.timings.isEmpty)
  }

  @Test func theSameFrameTimestampPresentedTwiceIsTwoFramesAndTwoSamples() {
    let metrics = ScreenSharingMetrics()
    for _ in 0..<2 {
      #expect(metrics.recordPresentation(isNewFrame: true, presentedAt: 2, submittedAt: 1.9, receivedAt: 1.8))
    }
    let result = metrics.snapshot()
    #expect(result.counters["presentedFrames"] == 2)
    #expect(result.counters["presentationCallbacks"] == 2)
    #expect(result.timings["submissionToPresentation"]?.count == 2)
    // The interval is a subtraction of two doubles, so it is compared as one.
    #expect((result.timings["submissionToPresentation"]?.maximumMs).map { abs($0 - 100) < 1e-9 } == true)
  }

  /// The receiver timestamp is absent for a frame the renderer redrew from its
  /// own cache upstream; the submission latency is still worth having.
  @Test func aFrameWithoutAReceiveTimeStillTimesItsSubmission() {
    let metrics = ScreenSharingMetrics()
    #expect(metrics.recordPresentation(isNewFrame: true, presentedAt: 3, submittedAt: 2, receivedAt: nil))
    let result = metrics.snapshot()
    #expect(result.timings["submissionToPresentation"]?.p50Ms == 1000)
    #expect(result.timings["receiverCallbackToPresentation"] == nil)
  }

  /// Zero is a sample, not a missing one: submission and presentation can share
  /// a timestamp, and that must not read as "never measured".
  @Test func aZeroLengthLatencyIsRecordedRatherThanDropped() {
    let metrics = ScreenSharingMetrics()
    #expect(metrics.recordPresentation(isNewFrame: true, presentedAt: 2, submittedAt: 2, receivedAt: 2))
    let result = metrics.snapshot()
    #expect(result.timings["submissionToPresentation"]?.count == 1)
    #expect(result.timings["submissionToPresentation"]?.p50Ms == 0)
    #expect(result.timings["receiverCallbackToPresentation"]?.count == 1)
  }

  /// Presentations arriving out of order across frames: every one is counted,
  /// and the percentiles come from the intervals that were measurable.
  @Test func outOfOrderPresentationsKeepTheCountersMonotone() {
    let metrics = ScreenSharingMetrics()
    let presentations: [(presentedAt: Double, submittedAt: Double)] = [
      (10, 9.9), (9.5, 9.6), (10.2, 10.0), (10.1, 10.15), (10.4, 10.1),
    ]
    for presentation in presentations {
      #expect(
        metrics.recordPresentation(
          isNewFrame: true, presentedAt: presentation.presentedAt, submittedAt: presentation.submittedAt,
          receivedAt: nil))
    }
    let result = metrics.snapshot()
    #expect(result.counters["presentedFrames"] == 5)
    #expect(result.counters["unpresentedDrawables"] == nil)
    let timing = result.timings["submissionToPresentation"]
    #expect(timing?.count == 3, "the two backwards intervals are dropped, the frames are not")
    #expect((timing?.maximumMs).map { abs($0 - 300) < 1e-9 } == true)
  }
}
