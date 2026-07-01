import SwiftUI

/// Scene-scoped creation actions published by the sidebar (via
/// `.focusedSceneValue`) so the File menu drives the exact same code paths as
/// the sidebar's own buttons. Absent during onboarding — the sidebar isn't on
/// screen — which leaves the menu items disabled.
struct SidebarActions: Equatable {
    let newChat: @MainActor () -> Void
    let newProject: @MainActor () -> Void

    /// The closures capture stable references (bindings and the app
    /// environment), so any published instance is interchangeable.
    static func == (lhs: SidebarActions, rhs: SidebarActions) -> Bool { true }
}

private struct SidebarActionsKey: FocusedValueKey {
    typealias Value = SidebarActions
}

/// Published by the new-chat page so ⌘N moves first-responder focus into the
/// composer even when that page is already on screen (navigating to it covers
/// the other case: the composer grabs focus as it appears).
struct NewChatComposerFocus: Equatable {
    let focus: @MainActor () -> Void

    static func == (lhs: NewChatComposerFocus, rhs: NewChatComposerFocus) -> Bool { true }
}

private struct NewChatComposerFocusKey: FocusedValueKey {
    typealias Value = NewChatComposerFocus
}

extension FocusedValues {
    var sidebarActions: SidebarActions? {
        get { self[SidebarActionsKey.self] }
        set { self[SidebarActionsKey.self] = newValue }
    }

    var newChatComposerFocus: NewChatComposerFocus? {
        get { self[NewChatComposerFocusKey.self] }
        set { self[NewChatComposerFocusKey.self] = newValue }
    }
}

/// The File > New items. Replaces the default "New Window" so ⌘N creates a
/// chat — the app's primary "new document" action.
struct FileCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            NewChatMenuItem()
            NewProjectMenuItem()
        }
    }
}

private struct NewChatMenuItem: View {
    @FocusedValue(\.sidebarActions) private var actions
    @FocusedValue(\.newChatComposerFocus) private var composerFocus

    var body: some View {
        Button("New Chat") {
            actions?.newChat()
            // Already on the new-chat page: navigation is a no-op, so move
            // focus into the composer directly.
            composerFocus?.focus()
        }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(actions == nil)
    }
}

private struct NewProjectMenuItem: View {
    @FocusedValue(\.sidebarActions) private var actions

    var body: some View {
        Button("New Project…") { actions?.newProject() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(actions == nil)
    }
}
