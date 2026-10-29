package struct ScreenSharingOnGlassEstimate: Equatable, Sendable {
  package let displayLinkTargetNs: Int64?
  package let replacesMissingPresentedTime: Bool

  package init(displayLinkTargetNs: Int64?, replacesMissingPresentedTime: Bool) {
    self.displayLinkTargetNs = displayLinkTargetNs
    self.replacesMissingPresentedTime = replacesMissingPresentedTime
  }
}
