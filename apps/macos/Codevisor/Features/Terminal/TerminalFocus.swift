import SwiftUI
import AppKit
import CodevisorCore
import GhosttyKit

/// Moves AppKit first-responder focus between the composer's text view and the
/// session's pane group (its selected pane). Holds weak references so it never
/// keeps views alive. Owned by the session screen and (composer-only) the
/// new-chat page.
@MainActor
final class TerminalFocusController {
    weak var composerTextView: NSView?
    weak var paneGroup: PaneGroupModel?
    private var typeToFocusMonitor: Any?

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
        paneGroup?.focusSelectedPane()
    }

    /// Makes ordinary typing anywhere in the session move focus into the
    /// composer without dropping the first character. The monitor is scoped
    /// to the active session screen and removed when that screen disappears.
    func startTypeToFocus() {
        guard typeToFocusMonitor == nil else { return }
        typeToFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleTypeToFocus(event) ?? event
        }
    }

    func stopTypeToFocus() {
        guard let typeToFocusMonitor else { return }
        NSEvent.removeMonitor(typeToFocusMonitor)
        self.typeToFocusMonitor = nil
    }

    private func handleTypeToFocus(_ event: NSEvent) -> NSEvent? {
        guard let textView = composerTextView as? NSTextView,
              textView.isEditable,
              let window = textView.window,
              event.window === window,
              window.isKeyWindow,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil,
              window.firstResponder !== textView,
              let text = Self.typeToFocusText(for: event) else {
            return event
        }

        // Never steal input from another editor or from the terminal. AppKit
        // represents an active text field with its NSTextView field editor.
        if window.firstResponder is NSTextView ||
            window.firstResponder is NSTextField ||
            window.firstResponder is Ghostty.SurfaceView {
            return event
        }

        guard window.makeFirstResponder(textView) else { return event }
        textView.insertText(text, replacementRange: textView.selectedRange())
        return nil
    }

    private static func typeToFocusText(for event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection([.command, .control, .option, .function]).isEmpty,
              event.specialKey == nil,
              let characters = event.characters,
              !characters.isEmpty,
              characters.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return characters
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
