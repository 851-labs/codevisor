import Foundation

extension ScreenSharingMetrics {
  /// Metal calls presented handlers for skipped drawables too. Only a positive
  /// presentedTime establishes on-screen presentation. All times use CA's clock.
  @discardableResult
  public func recordPresentation(
    isNewFrame: Bool, presentedAt: Double, submittedAt: Double, receivedAt: Double?
  ) -> Bool {
    guard isNewFrame else { return false }
    increment("presentationCallbacks")
    guard presentedAt.isFinite, presentedAt > 0 else {
      increment("unpresentedDrawables")
      return false
    }
    increment("presentedFrames")
    observe("submissionToPresentation", milliseconds: (presentedAt - submittedAt) * 1000)
    if let receivedAt {
      observe("receiverCallbackToPresentation", milliseconds: (presentedAt - receivedAt) * 1000)
    }
    return true
  }
}
