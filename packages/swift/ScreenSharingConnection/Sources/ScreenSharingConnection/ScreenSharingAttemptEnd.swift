public enum ScreenSharingAttemptEnd: Error, Equatable, Sendable {
  case dropped(ScreenSharingFailureReason)
  case refused(ScreenSharingFailureReason)
}
