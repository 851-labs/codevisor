import Foundation

extension ScreenSharingMetrics {
  public func recordPresentation(
    isNewFrame: Bool, presentedAt: Double, submittedAt: Double, receivedAt: Double?
  ) {
    guard isNewFrame else { return }
    increment("presentationCallbacks")
    guard presentedAt.isFinite, presentedAt > 0 else {
      increment("unpresentedDrawables")
      return
    }
    increment("presentedFrames")
    observe("submissionToPresentation", milliseconds: (presentedAt - submittedAt) * 1000)
    if let receivedAt {
      observe("receiverCallbackToPresentation", milliseconds: (presentedAt - receivedAt) * 1000)
    }
  }
}
