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

  @Test("Settled workspaces retain no promotion-owned UI")
  func settledOwnershipIsCanonical() {
    let resources = NewChatPromotionLifecycleContract.resources(for: .settled)

    #expect(!resources.keepsNativeSheet)
    #expect(!resources.keepsTransitionSurface)
    #expect(!resources.usesPortaledComposer)
    #expect(!resources.retainsComposerEditorAfterSheetDismissal)
    #expect(resources.usesCanonicalWorkspaceNavigation)
  }

  @Test("Ordinary sheet composition keeps the editor inside the native sheet")
  func composingDoesNotPortalEditor() {
    let resources = NewChatPromotionLifecycleContract.resources(for: .composing)

    #expect(resources.keepsNativeSheet)
    #expect(!resources.keepsTransitionSurface)
    #expect(!resources.usesPortaledComposer)
    #expect(!resources.retainsComposerEditorAfterSheetDismissal)
    #expect(!resources.usesCanonicalWorkspaceNavigation)
  }

  @Test("The editor remains in the live composer throughout the flight")
  func animatingDoesNotPortalEditor() {
    let resources = NewChatPromotionLifecycleContract.resources(for: .animating)
    #expect(resources.keepsNativeSheet)
    #expect(resources.keepsTransitionSurface)
    #expect(!resources.usesPortaledComposer)
    #expect(!resources.retainsComposerEditorAfterSheetDismissal)
  }

  @Test("The editor portal exists only during the structural handoff")
  func editorPortalIsTransient() {
    for phase in [NewChatPromotionPhase.committing] {
      let resources = NewChatPromotionLifecycleContract.resources(for: phase)

      #expect(resources.keepsNativeSheet)
      #expect(resources.keepsTransitionSurface)
      #expect(resources.usesPortaledComposer)
      #expect(resources.retainsComposerEditorAfterSheetDismissal)
      #expect(!resources.usesCanonicalWorkspaceNavigation)
    }
  }

  @Test("Closing and reopening preserves draft data, not editor identity")
  func ordinarySheetReopenStartsWithFreshEditorOwnership() {
    let beforeDismiss = NewChatPromotionLifecycleContract.resources(for: .composing)
    let afterReopen = NewChatPromotionLifecycleContract.resources(for: .composing)

    #expect(!beforeDismiss.retainsComposerEditorAfterSheetDismissal)
    #expect(!afterReopen.usesPortaledComposer)
    #expect(!afterReopen.retainsComposerEditorAfterSheetDismissal)
  }
}
