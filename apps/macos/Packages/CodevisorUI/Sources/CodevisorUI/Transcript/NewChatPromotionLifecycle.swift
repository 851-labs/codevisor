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
/// this separate from UIKit makes the ownership boundary explicit: neither a
/// temporary presentation surface nor a portaled composer may survive the
/// transition's terminal state.
public enum NewChatPromotionLifecycleContract {
    public static func canCommit(
        phase: NewChatPromotionPhase,
        canonicalWorkspaceReady: Bool,
        surfaceAnimationFinished: Bool
    ) -> Bool {
        phase == .animating
            && canonicalWorkspaceReady
            && surfaceAnimationFinished
    }

    public static func resources(
        for phase: NewChatPromotionPhase
    ) -> NewChatPromotionResources {
        switch phase {
        case .composing:
            NewChatPromotionResources(
                keepsNativeSheet: true,
                keepsTransitionSurface: false,
                usesPortaledComposer: false,
                retainsComposerEditorAfterSheetDismissal: false,
                usesCanonicalWorkspaceNavigation: false
            )
        case .animating, .committing:
            NewChatPromotionResources(
                keepsNativeSheet: true,
                keepsTransitionSurface: true,
                usesPortaledComposer: true,
                retainsComposerEditorAfterSheetDismissal: true,
                usesCanonicalWorkspaceNavigation: false
            )
        case .settled:
            NewChatPromotionResources(
                keepsNativeSheet: false,
                keepsTransitionSurface: false,
                usesPortaledComposer: false,
                retainsComposerEditorAfterSheetDismissal: false,
                usesCanonicalWorkspaceNavigation: true
            )
        }
    }
}

public struct NewChatPromotionResources: Equatable, Sendable {
    public let keepsNativeSheet: Bool
    public let keepsTransitionSurface: Bool
    public let usesPortaledComposer: Bool
    /// True only while the modal is being structurally replaced by its real
    /// workspace route. An ordinary dismissed compose sheet persists its
    /// draft value, never its concrete UIKit/AppKit editor instance.
    public let retainsComposerEditorAfterSheetDismissal: Bool
    public let usesCanonicalWorkspaceNavigation: Bool

    public init(
        keepsNativeSheet: Bool,
        keepsTransitionSurface: Bool,
        usesPortaledComposer: Bool,
        retainsComposerEditorAfterSheetDismissal: Bool,
        usesCanonicalWorkspaceNavigation: Bool
    ) {
        self.keepsNativeSheet = keepsNativeSheet
        self.keepsTransitionSurface = keepsTransitionSurface
        self.usesPortaledComposer = usesPortaledComposer
        self.retainsComposerEditorAfterSheetDismissal =
            retainsComposerEditorAfterSheetDismissal
        self.usesCanonicalWorkspaceNavigation = usesCanonicalWorkspaceNavigation
    }
}
