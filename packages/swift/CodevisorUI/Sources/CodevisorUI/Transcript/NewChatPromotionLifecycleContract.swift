/// The presentation lifecycle for creating a chat from iOS's native New Chat
/// sheet. The transition is deliberately finite: once settled, Home's normal
/// workspace route is the only remaining owner of navigation and content.
public enum NewChatPromotionPhase: Equatable, Sendable {
  case composing
  case animating
  case committing
  case settled
}

/// Pure policy shared by the iOS handoff coordinator and its tests. Keeping
/// this separate from UIKit makes the commit gate explicit: the sheet hands
/// off to the workspace route only once, and only after every owner is done.
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
