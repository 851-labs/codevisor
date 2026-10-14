public enum NewChatPromotionPhase: Equatable, Sendable {
  case composing
  case animating
  case committing
  case settled
}

public enum NewChatPromotionLifecycleContract {
  public static func canCommit(
    phase: NewChatPromotionPhase,
    canonicalWorkspaceReady: Bool,
    surfaceAnimationFinished: Bool,
    sendAnimationFinished: Bool
  ) -> Bool {
    phase == .animating
      && canonicalWorkspaceReady
      && surfaceAnimationFinished
      && sendAnimationFinished
  }
}
