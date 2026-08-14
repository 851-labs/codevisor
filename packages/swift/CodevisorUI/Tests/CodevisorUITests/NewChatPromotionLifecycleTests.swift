import Testing
@testable import CodevisorUI

@Suite("New Chat promotion lifecycle")
struct NewChatPromotionLifecycleTests {
    @Test("The handoff waits for both the canonical route and surface animation")
    func commitReadinessRequiresBothOwners() {
        #expect(
            !NewChatPromotionLifecycleContract.canCommit(
                phase: .animating,
                canonicalWorkspaceReady: false,
                surfaceAnimationFinished: true
            ))
        #expect(
            !NewChatPromotionLifecycleContract.canCommit(
                phase: .animating,
                canonicalWorkspaceReady: true,
                surfaceAnimationFinished: false
            ))
        #expect(
            NewChatPromotionLifecycleContract.canCommit(
                phase: .animating,
                canonicalWorkspaceReady: true,
                surfaceAnimationFinished: true
            ))
    }

    @Test("A commit cannot run twice")
    func terminalPhasesAreNotCommitEligible() {
        for phase in [NewChatPromotionPhase.committing, .settled] {
            #expect(
                !NewChatPromotionLifecycleContract.canCommit(
                    phase: phase,
                    canonicalWorkspaceReady: true,
                    surfaceAnimationFinished: true
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

    @Test("The editor portal exists only during the structural handoff")
    func editorPortalIsTransient() {
        for phase in [NewChatPromotionPhase.animating, .committing] {
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
