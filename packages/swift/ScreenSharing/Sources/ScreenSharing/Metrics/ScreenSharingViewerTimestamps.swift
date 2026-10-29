public struct ScreenSharingViewerTimestamps: Codable, Equatable, Sendable {
  public let decodeInputNs: Int64
  public let decodeSubmitNs: Int64
  public let decodeOutputNs: Int64
  public let mailboxPutNs: Int64?
  public let renderCommitNs: Int64
  public let gpuCompletedNs: Int64?
  public let displayLinkTargetNs: Int64?
  public let onGlassNs: Int64?
  public let onGlassSource: ScreenSharingOnGlassSource?

  init(
    decoded: ScreenSharingDecodedFrameTiming, presentation: ScreenSharingFramePresentation,
    estimate: ScreenSharingOnGlassEstimate
  ) {
    decodeInputNs = decoded.decodeInputNs
    decodeSubmitNs = decoded.decodeSubmitNs
    decodeOutputNs = decoded.decodedNs
    mailboxPutNs = presentation.receivedAtNs
    renderCommitNs = presentation.submittedAtNs
    gpuCompletedNs = presentation.gpuCompletedNs
    displayLinkTargetNs = estimate.displayLinkTargetNs
    (onGlassNs, onGlassSource) = Self.onGlass(presentation, estimate: estimate)
  }

  private static func onGlass(
    _ presentation: ScreenSharingFramePresentation, estimate: ScreenSharingOnGlassEstimate
  ) -> (Int64?, ScreenSharingOnGlassSource?) {
    if let presented = presentation.presentedAtNs { return (presented, .presentedTime) }
    guard estimate.replacesMissingPresentedTime, let target = estimate.displayLinkTargetNs else { return (nil, nil) }
    return (target, .displayLinkTarget)
  }
}
