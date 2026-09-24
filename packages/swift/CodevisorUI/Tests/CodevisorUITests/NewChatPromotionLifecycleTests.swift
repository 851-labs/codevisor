import Testing
@testable import CodevisorUI

@Suite("New Chat promotion lifecycle")
struct NewChatPromotionLifecycleTests {
  @Test("The sheet stays live until both animations land and the route is ready")
  func commitReadinessRequiresEveryOwner() {
    // Exercise every completion order, including a fast sheet expansion
    // and a destination ready while the bubble is still leaving the editor.
    for workspace in [false, true] {
      for surface in [false, true] {
        for send in [false, true] {
          #expect(
            NewChatPromotionLifecycleContract.canCommit(
              phase: .animating,
              canonicalWorkspaceReady: workspace,
              surfaceAnimationFinished: surface,
              sendAnimationFinished: send
            ) == (workspace && surface && send))
        }
      }
    }
  }

  @Test("A commit cannot run twice")
  func terminalPhasesAreNotCommitEligible() {
    for phase in [NewChatPromotionPhase.committing, .settled] {
      #expect(
        !NewChatPromotionLifecycleContract.canCommit(
          phase: phase,
          canonicalWorkspaceReady: true,
          surfaceAnimationFinished: true,
          sendAnimationFinished: true
        ))
    }
  }
}
