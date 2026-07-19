import SwiftUI
import AppKit

/// Semantic keys the question picker steers with. The AppKit anchor
/// translates raw key events into these so the picker's handler stays free
/// of NSEvent details.
enum QuestionPickerKey: Equatable {
    case up
    case down
    case left
    case right
    case space
    case enter
    case escape
    case digit(Int)
}

/// The question picker's AppKit keyboard anchor.
///
/// SwiftUI `@FocusState` is unreliable here: the picker mounts through the
/// composer card's animated state swap, and a `focused = true` written in
/// `onAppear` — while the view is still animating into the key window's
/// responder chain and the outgoing composer `NSTextView` is being torn
/// down — is silently dropped by AppKit-backed SwiftUI, leaving nothing
/// focused and `.onKeyPress` deaf. The composer solved the same
/// mount-before-window race with the focus controller's
/// `makeFirstResponder` + retry; this zero-chrome view is the picker's
/// handle into that exact mechanism: it holds first responder for the
/// option list and routes `keyDown` to the picker's semantic handler.
struct QuestionPickerFocusAnchor: NSViewRepresentable {
    /// Fired (async, so mid-insertion responder churn has settled) whenever
    /// the anchor lands in a window: the caller registers it with the
    /// session's focus controller — mirroring `ChatInputEditor.onTextViewReady`.
    var onAttach: (QuestionPickerKeyView) -> Void
    /// Returns true when the key was handled (consumed).
    var onKey: (QuestionPickerKey) -> Bool
    /// The anchor is leaving its window (question resolved, chat
    /// unmounting): the caller unregisters it and hands focus back.
    var onDetach: (QuestionPickerKeyView) -> Void

    func makeNSView(context: Context) -> QuestionPickerKeyView {
        let view = QuestionPickerKeyView()
        view.onAttach = onAttach
        view.onKey = onKey
        view.onDetach = onDetach
        return view
    }

    func updateNSView(_ view: QuestionPickerKeyView, context: Context) {
        view.onAttach = onAttach
        view.onKey = onKey
        view.onDetach = onDetach
    }
}

final class QuestionPickerKeyView: NSView {
    var onAttach: ((QuestionPickerKeyView) -> Void)?
    var onKey: ((QuestionPickerKey) -> Bool)?
    var onDetach: ((QuestionPickerKeyView) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// Purely a keyboard anchor — never intercept the picker's clicks
    /// (option rows, buttons, the notes editor).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Fires while still attached, so the unregister path can inspect
        // the current window's first responder to decide focus handoff.
        if newWindow == nil { onDetach?(self) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Next runloop turn: the composer→picker swap's teardown settles
        // first, so registration's polite focus grab judges the REAL
        // post-swap responder (usually the window) instead of a view
        // that's mid-removal.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.onAttach?(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if let key = Self.semanticKey(for: event), onKey?(key) == true {
            return
        }
        // Unmodified typing dies here silently (parity with the web
        // picker: stray letters neither beep nor fall through); modified
        // and function keys keep their responder-chain behavior.
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad])
        if mods.isEmpty, event.charactersIgnoringModifiers?.isEmpty == false {
            return
        }
        super.keyDown(with: event)
    }

    private static func semanticKey(for event: NSEvent) -> QuestionPickerKey? {
        // Arrow keys carry implicit .function/.numericPad flags — strip
        // them or plain arrows read as modified (same trick as the focus
        // controller's tab-command matching).
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])
        guard mods.isEmpty else { return nil }
        switch event.specialKey {
        case .upArrow: return .up
        case .downArrow: return .down
        case .leftArrow: return .left
        case .rightArrow: return .right
        default: break
        }
        // 36 = Return, 76 = keypad Enter, 53 = Escape (the same codes the
        // composer's SubmittingTextView matches).
        switch event.keyCode {
        case 36, 76: return .enter
        case 53: return .escape
        default: break
        }
        guard let characters = event.charactersIgnoringModifiers else { return nil }
        if characters == " " { return .space }
        if characters.count == 1,
           let digit = characters.first?.wholeNumberValue,
           (1...9).contains(digit) {
            return .digit(digit)
        }
        return nil
    }
}
