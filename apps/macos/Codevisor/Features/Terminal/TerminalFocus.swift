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
    weak var composerTextView: SubmittingTextView?
    /// The chat history's scroll view. Clicks anywhere inside it park keyboard
    /// focus on it (blurring a focused terminal) so typing can hand off to the
    /// composer.
    weak var transcriptView: NSView?
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
    /// composer without dropping the first character, and makes a click
    /// anywhere in the chat history move keyboard focus onto the history (so
    /// a focused terminal stops receiving keystrokes). The monitor is scoped
    /// to the active session screen and removed when that screen disappears.
    func startTypeToFocus() {
        guard typeToFocusMonitor == nil else { return }
        typeToFocusMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown: return self.handleTypeToFocus(event)
            case .leftMouseDown: return self.handleTranscriptClick(event)
            default: return event
            }
        }
    }

    func stopTypeToFocus() {
        guard let typeToFocusMonitor else { return }
        NSEvent.removeMonitor(typeToFocusMonitor)
        self.typeToFocusMonitor = nil
    }

    private func handleTypeToFocus(_ event: NSEvent) -> NSEvent? {
        guard let textView = composerTextView,
              textView.isEditable,
              let window = textView.window,
              event.window === window,
              window.isKeyWindow,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil,
              window.firstResponder !== textView,
              Self.isTypeToFocusEvent(event) else {
            return event
        }

        // Preserve real editing sessions and terminal input. Read-only
        // transcript text is also an NSTextView, but ordinary typing there is
        // exactly what should move focus into the composer. AppKit represents
        // an active NSTextField with its editable NSTextView field editor.
        if let currentTextView = window.firstResponder as? NSTextView,
           currentTextView.isEditable {
            return event
        }
        if let currentTextField = window.firstResponder as? NSTextField,
           currentTextField.isEditable {
            return event
        }
        if window.firstResponder is Ghostty.SurfaceView {
            return event
        }

        guard window.makeFirstResponder(textView) else { return event }

        // Local monitors run before NSApplication.sendEvent. Returning the
        // original event dispatches it to the new first responder, preserving
        // NSTextView's native key binding, undo, dead-key, and IME pipelines.
        return event
    }

    /// Pane-style focus for the chat history: a click that lands in it and
    /// that no view claims focus from — whitespace, a disclosure trigger, a
    /// row's inert chrome — parks keyboard focus on the history, exactly like
    /// a click in the terminal focuses the terminal. SwiftUI rows consume
    /// such clicks without ever touching the AppKit first responder, so
    /// without this a focused terminal keeps eating keystrokes after the user
    /// has clicked into the chat.
    ///
    /// The decision is deliberately made AFTER the click dispatches, never
    /// before: the transcript's selectable text views (and the composer's
    /// editor) claim first responder themselves as part of handling their
    /// mouseDown, and preempting that fights their native selection/caret
    /// behavior. If the first responder changed at all as a result of the
    /// click, the click "spent" its focus and is left alone.
    private func handleTranscriptClick(_ event: NSEvent) -> NSEvent? {
        guard let transcriptView,
              let window = transcriptView.window,
              event.window === window,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil,
              let transcriptSuperview = transcriptView.superview else {
            return event
        }
        // Geometry check scoped to the transcript's own subtree (hitTest takes
        // superview coordinates). Overlays that float inside the transcript's
        // frame — the composer card, scroll-to-bottom — are excluded by the
        // focus-change check below, not by geometry.
        let point = transcriptSuperview.convert(event.locationInWindow, from: nil)
        guard transcriptView.hitTest(point) != nil else { return event }

        let responderBeforeClick = window.firstResponder
        if let currentView = responderBeforeClick as? NSView,
           currentView.isDescendant(of: transcriptView) {
            return event // Focus already parked in the history.
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let transcriptView = self.transcriptView,
                  transcriptView.window === window,
                  // Someone claimed focus from this click (text selection,
                  // the composer, a menu): leave it alone.
                  window.firstResponder === responderBeforeClick else { return }
            window.makeFirstResponder(transcriptView)
        }
        return event
    }

    private static func isTypeToFocusEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection([.command, .control, .function]).isEmpty,
              event.specialKey == nil else {
            return false
        }

        // Keep Space available for scrolling and Full Keyboard Access button
        // activation when the composer is not focused. Option is deliberately
        // allowed because it produces text on many keyboard layouts; dead-key
        // events may have no characters yet and must still reach NSTextView.
        return event.characters != " " && event.characters != "\u{00A0}"
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
