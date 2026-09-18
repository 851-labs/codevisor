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
}
