import SwiftUI
import AppKit
import HerdManCore

/// Moves AppKit first-responder focus between the composer's text view and the
/// terminal surface for a session. Holds weak references so it never keeps views
/// alive. Owned by the session screen and (composer-only) the new-chat page.
@MainActor
final class TerminalFocusController {
    weak var composerTextView: NSView?
    weak var terminal: TerminalSession?

    func apply(_ target: SessionFocusTarget) {
        switch target {
        case .composer: focusComposer()
        case .terminal: focusTerminal()
        }
    }

    func focusComposer() {
        guard let view = composerTextView else { return }
        view.window?.makeFirstResponder(view)
    }

    func focusTerminal() {
        guard let surface = terminal?.ensureSurface() else { return }
        let view = surface.nsView
        view.window?.makeFirstResponder(view)
        surface.setFocused(true)
    }
}

/// A scene-scoped action that toggles the focused session's terminal. Published
/// by the session screen and invoked by the ⌘J menu command so the shortcut
/// works regardless of whether the composer or terminal currently has focus.
struct TerminalToggleAction: Equatable {
    let sessionId: UUID
    let toggle: @MainActor () -> Void

    static func == (lhs: TerminalToggleAction, rhs: TerminalToggleAction) -> Bool {
        lhs.sessionId == rhs.sessionId
    }
}

private struct TerminalToggleKey: FocusedValueKey {
    typealias Value = TerminalToggleAction
}

extension FocusedValues {
    var terminalToggle: TerminalToggleAction? {
        get { self[TerminalToggleKey.self] }
        set { self[TerminalToggleKey.self] = newValue }
    }
}

/// The ⌘J command. Reads the focused session's toggle action and invokes it.
struct TerminalCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            TerminalToggleMenuItem()
        }
    }
}

private struct TerminalToggleMenuItem: View {
    @FocusedValue(\.terminalToggle) private var action

    var body: some View {
        Button("Toggle terminal") { action?.toggle() }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(action == nil)
    }
}
