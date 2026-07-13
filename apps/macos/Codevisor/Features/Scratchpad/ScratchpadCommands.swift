import SwiftUI

/// A scene-scoped action that toggles the focused session's scratchpad
/// inspector. Published by the session container and invoked by the ⌥⌘I menu
/// command, mirroring `TerminalToggleAction`.
struct ScratchpadToggleAction: Equatable {
    let sessionId: UUID
    let toggle: @MainActor () -> Void

    static func == (lhs: ScratchpadToggleAction, rhs: ScratchpadToggleAction) -> Bool {
        lhs.sessionId == rhs.sessionId
    }
}

private struct ScratchpadToggleKey: FocusedValueKey {
    typealias Value = ScratchpadToggleAction
}

extension FocusedValues {
    var scratchpadToggle: ScratchpadToggleAction? {
        get { self[ScratchpadToggleKey.self] }
        set { self[ScratchpadToggleKey.self] = newValue }
    }
}

/// List-formatting actions published by the scratchpad editor while it has
/// keyboard focus (`.focusedValue`, not scene-scoped), so the Format-menu
/// items only light up when the notes are actually being edited.
struct ScratchpadFormatActions: Equatable {
    let sessionId: UUID
    let toggleBullet: @MainActor () -> Void

    static func == (lhs: ScratchpadFormatActions, rhs: ScratchpadFormatActions) -> Bool {
        lhs.sessionId == rhs.sessionId
    }
}

private struct ScratchpadFormatKey: FocusedValueKey {
    typealias Value = ScratchpadFormatActions
}

extension FocusedValues {
    var scratchpadFormat: ScratchpadFormatActions? {
        get { self[ScratchpadFormatKey.self] }
        set { self[ScratchpadFormatKey.self] = newValue }
    }
}

/// The scratchpad menu commands: ⌥⌘I toggles the inspector (View-adjacent,
/// next to "Toggle terminal"), and the bulleted-list item lands in the
/// Format menu contributed by `TextFormattingCommands` (shortcut follows
/// Apple Notes: ⇧⌘7).
struct ScratchpadCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            ScratchpadToggleMenuItem()
        }
        CommandGroup(after: .textFormatting) {
            ScratchpadFormatMenuItems()
        }
    }
}

private struct ScratchpadToggleMenuItem: View {
    @FocusedValue(\.scratchpadToggle) private var action

    var body: some View {
        Button("Toggle Scratchpad") { action?.toggle() }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(action == nil)
    }
}

private struct ScratchpadFormatMenuItems: View {
    @FocusedValue(\.scratchpadFormat) private var actions

    var body: some View {
        Button("Bulleted List") { actions?.toggleBullet() }
            .keyboardShortcut("7", modifiers: [.command, .shift])
            .disabled(actions == nil)
    }
}
