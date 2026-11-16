public enum ScreenSharingFailureAction: Equatable, Sendable {
  case viewHere
  case connect
  case retry

  public init?(for reason: ScreenSharingFailureReason) {
    switch reason {
    case .takenOver, .inUse: self = .viewHere
    case .stoppedOnHost: self = .connect
    case .updateNeeded, .unsupportedOnThisDevice: return nil
    case .cantReach, .inUseOldHost, .displayAsleep, .sessionSwitched, .noDisplay, .noWorkspace, .nothingToView,
      .permissionMissing, .networkBlocked, .noVideo, .keptDropping, .unclassified:
      self = .retry
    }
  }
}
