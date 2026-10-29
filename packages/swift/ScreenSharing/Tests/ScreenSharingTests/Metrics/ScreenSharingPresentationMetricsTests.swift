import Testing
@testable import ScreenSharing

struct ScreenSharingPresentationMetricsTests {
  @Test func skippedDrawablesAndRedrawsDoNotCountAsNewPresentedFrames() {
    let metrics = ScreenSharingMetrics()
    metrics.recordPresentation(isNewFrame: true, presentedAt: 0, submittedAt: 1, receivedAt: 0.5)
    metrics.recordPresentation(isNewFrame: false, presentedAt: 2, submittedAt: 1, receivedAt: 0.5)
    metrics.recordPresentation(isNewFrame: true, presentedAt: 2, submittedAt: 1.75, receivedAt: 1.5)
    let result = metrics.snapshot()
    #expect(result.counters["presentationCallbacks"] == 2)
    #expect(result.counters["unpresentedDrawables"] == 1)
    #expect(result.counters["presentedFrames"] == 1)
    #expect(result.timings["submissionToPresentation"]?.p50Ms == 250)
    #expect(result.timings["receiverCallbackToPresentation"]?.p50Ms == 500)
  }

  @Test func aPresentationTimeBeforeSubmissionCountsTheFrameAndDiscardsTheInterval() {
    let metrics = ScreenSharingMetrics()
    metrics.recordPresentation(isNewFrame: true, presentedAt: 1, submittedAt: 2, receivedAt: 0.5)
    let result = metrics.snapshot()
    #expect(result.counters["presentedFrames"] == 1)
    #expect(result.timings["submissionToPresentation"] == nil, "a negative latency would poison the percentiles")
    #expect(result.timings["receiverCallbackToPresentation"]?.count == 1)
    #expect(result.timings["receiverCallbackToPresentation"]?.p50Ms == 500)
  }

  @Test(arguments: [Double.nan, .infinity, -.infinity, -1, -0.0, 0])
  func aTimeThatCannotBeAPresentationIsAnUnpresentedDrawable(presentedAt: Double) {
    let metrics = ScreenSharingMetrics()
    metrics.recordPresentation(isNewFrame: true, presentedAt: presentedAt, submittedAt: 1, receivedAt: 0.5)
    let result = metrics.snapshot()
    #expect(result.counters["presentationCallbacks"] == 1)
    #expect(result.counters["unpresentedDrawables"] == 1)
    #expect(result.counters["presentedFrames"] == nil)
    #expect(result.timings.isEmpty, "an unpresented drawable has no latency to report")
  }

  @Test func aRedrawLeavesTheAccountingUntouched() {
    let metrics = ScreenSharingMetrics()
    metrics.recordPresentation(isNewFrame: false, presentedAt: 2, submittedAt: 1, receivedAt: 0.5)
    let result = metrics.snapshot()
    #expect(result.counters.isEmpty)
    #expect(result.timings.isEmpty)
  }

  @Test func theSameFrameTimestampPresentedTwiceIsTwoFramesAndTwoSamples() {
    let metrics = ScreenSharingMetrics()
    for _ in 0..<2 {
      metrics.recordPresentation(isNewFrame: true, presentedAt: 2, submittedAt: 1.9, receivedAt: 1.8)
    }
    let result = metrics.snapshot()
    #expect(result.counters["presentedFrames"] == 2)
    #expect(result.counters["presentationCallbacks"] == 2)
    #expect(result.timings["submissionToPresentation"]?.count == 2)
    #expect((result.timings["submissionToPresentation"]?.maximumMs).map { abs($0 - 100) < 1e-9 } == true)
  }

  @Test func aFrameWithoutAReceiveTimeStillTimesItsSubmission() {
    let metrics = ScreenSharingMetrics()
    metrics.recordPresentation(isNewFrame: true, presentedAt: 3, submittedAt: 2, receivedAt: nil)
    let result = metrics.snapshot()
    #expect(result.timings["submissionToPresentation"]?.p50Ms == 1000)
    #expect(result.timings["receiverCallbackToPresentation"] == nil)
  }

  @Test func aZeroLengthLatencyIsRecordedRatherThanDropped() {
    let metrics = ScreenSharingMetrics()
    metrics.recordPresentation(isNewFrame: true, presentedAt: 2, submittedAt: 2, receivedAt: 2)
    let result = metrics.snapshot()
    #expect(result.timings["submissionToPresentation"]?.count == 1)
    #expect(result.timings["submissionToPresentation"]?.p50Ms == 0)
    #expect(result.timings["receiverCallbackToPresentation"]?.count == 1)
  }

  @Test func outOfOrderPresentationsKeepTheCountersMonotone() {
    let metrics = ScreenSharingMetrics()
    let presentations: [(presentedAt: Double, submittedAt: Double)] = [
      (10, 9.9), (9.5, 9.6), (10.2, 10.0), (10.1, 10.15), (10.4, 10.1),
    ]
    for presentation in presentations {
      metrics.recordPresentation(
        isNewFrame: true, presentedAt: presentation.presentedAt, submittedAt: presentation.submittedAt,
        receivedAt: nil)
    }
    let result = metrics.snapshot()
    #expect(result.counters["presentedFrames"] == 5)
    #expect(result.counters["unpresentedDrawables"] == nil)
    let timing = result.timings["submissionToPresentation"]
    #expect(timing?.count == 3, "the two backwards intervals are dropped, the frames are not")
    #expect((timing?.maximumMs).map { abs($0 - 300) < 1e-9 } == true)
  }

  @Test func aPresentedFrameWithAnIdentityCompletesItsTimelineRecord() throws {
    let metrics = ScreenSharingMetrics()
    metrics.timeline.decoded(
      ScreenSharingDecodedFrameTiming(
        sourceTimestampNs: 42, host: nil, decodeInputNs: 1_000_000_000, decodeSubmitNs: 1_000_500_000,
        decodedNs: 1_002_000_000, isKeyFrame: true))
    metrics.recordPresentation(isNewFrame: true, presentedAt: 1.02, submittedAt: 1.01, receivedAt: 1.003)
    metrics.recordPresentation(
      isNewFrame: true, presentedAt: 1.02, submittedAt: 1.01, receivedAt: 1.003, sourceTimestampNs: 42)

    let record = try #require(metrics.timeline.records(after: 0).first)
    #expect(record.stagesUs.decode == 2_000 && record.stagesUs.delivery == 1_000)
    #expect(record.stagesUs.renderQueue == 7_000 && record.stagesUs.present == 10_000)
    #expect(metrics.timeline.summary()?.incompleteFrames == 1, "a frame without host stages is incomplete")
  }
}
