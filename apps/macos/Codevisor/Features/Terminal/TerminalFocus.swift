import SwiftUI
import AppKit
import CodevisorCore
import GhosttyKit

/// Reports the hosting NSWindow to a callback (fires on mount and window
/// moves). Zero-sized; used by the session screen to anchor its focus
/// controller's key-command guard to the right window.
struct HostWindowCapture: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    final class CaptureView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onWindow = onWindow
    }
}

/// Moves AppKit first-responder focus between the composer's text view and the
/// session's pane group (its selected pane). Holds weak references so it never
/// keeps views alive. Owned by the session screen and (composer-only) the
/// new-chat page.
@MainActor
final class TerminalFocusController {

    weak var composerTextView: SubmittingTextView?
    /// The window hosting the session screen, captured by the screen itself.
    /// The tab-command guard anchors here — NOT to the composer's window:
    /// the composer unmounts whenever a non-chat tab (terminal, New tab
    /// page) is selected, and ⌘T must keep working then (falling through
    /// would reach the Format menu's Fonts panel). Also the anchor for the
    /// ONE first-responder observer (the upward focus-feedback path).
    weak var hostWindow: NSWindow? {
        didSet { observeFirstResponder() }
    }

    /// The single upward feedback path for composer focus: the user clicked
    /// (or tabbed) into some chat's composer — the container activates that
    /// chat's group, keeping "active group" true to where the keyboard is.
    /// (Terminal surfaces report the same through their own responder
    /// overrides.)
    var onChatComposerFocused: ((UUID) -> Void)?

    private var responderObservation: NSKeyValueObservation?

    private func observeFirstResponder() {
        responderObservation = hostWindow?.observe(
            \.firstResponder, options: [.new]
        ) { [weak self] window, _ in
            let responder = window.firstResponder
            Task { @MainActor [weak self] in
                self?.firstResponderChanged(responder)
            }
        }
    }

    private func firstResponderChanged(_ responder: NSResponder?) {
        guard let view = responder as? NSView else { return }
        for (chatId, box) in chatComposers {
            if let composer = box.view, view === composer || view.isDescendant(of: composer) {
                onChatComposerFocused?(chatId)
                return
            }
        }
        // A chat's question picker is its composer-area surface while a
        // blocking question is up — focusing it activates the chat too.
        for (chatId, box) in chatQuestionPickers {
            if let picker = box.view, view === picker {
                onChatComposerFocused?(chatId)
                return
            }
        }
        for (chatId, box) in chatTranscripts {
            if let transcript = box.view, view === transcript || view.isDescendant(of: transcript) {
                onChatComposerFocused?(chatId)
                return
            }
        }
    }
    /// The chat history's scroll view. Clicks anywhere inside it park keyboard
    /// focus on it (blurring a focused terminal) so typing can hand off to the
    /// composer.
    weak var transcriptView: NSView?
    weak var paneGroup: PaneGroupModel?
    /// The session screen's panel toggle (it owns the open/close + focus
    /// handoff); group models across all split leaves relay ⌘J here.
    var requestPanelToggle: (() -> Void)?
    /// The session's center pane group: tab commands (⌘T/⌘W/⌘1-9/⌘⌥←→)
    /// pressed while the chat has focus act on it, mirroring how a focused
    /// terminal routes the same shortcuts to its own group.
    weak var centerGroup: PaneGroupModel?
    /// Whether the workspace has center tabs beyond the selected one (any
    /// group). Wired by the container against repository truth. ⌘W is
    /// CLAIMED while this is true even when the selected tab can't close
    /// (the anchoring chat) — falling through to Close Window with tabs
    /// still open is catastrophic; the window only becomes ⌘W's target
    /// once the workspace is down to its last tab.
    var hasOtherCenterTabs: (() -> Bool)?
    private var typeToFocusMonitor: Any?

    func apply(_ target: SessionFocusTarget) {
        switch target {
        case .composer: focusComposer()
        case .terminal: focusTerminal()
        }
    }

    /// Composer text views by CHAT SESSION, so multi-chat workspaces can
    /// focus the right one (the single `composerTextView` is whichever
    /// registered last — arbitrary with several chats mounted).
    private final class WeakTextView {
        weak var view: SubmittingTextView?
        init(_ view: SubmittingTextView) { self.view = view }
    }

    private var chatComposers: [UUID: WeakTextView] = [:]
    /// Chat transcript (history) views by session — the click-to-blur zones:
    /// a click in ANY chat's transcript parks focus there, taking the
    /// keyboard away from a focused terminal.
    private final class WeakNSView {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private var chatTranscripts: [UUID: WeakNSView] = [:]
    /// Question-picker key anchors by chat. While a chat shows a blocking
    /// agent question its composer is UNMOUNTED and the picker replaces it
    /// as the chat's one keyboard surface — so every composer-focus route
    /// (open sequence, pane/tab clicks, transcript clicks, type-to-focus)
    /// prefers a registered picker over the (dead) composer slot.
    private var chatQuestionPickers: [UUID: WeakNSView] = [:]
    /// A chat whose composer should take focus as soon as it CAN — the
    /// target pane may not have laid out yet (fresh workspace open, or a
    /// tab switch that remounts the chat), so the intent parks here and
    /// applies on registration.
    private var pendingComposerFocus: UUID?

    func registerComposer(_ view: SubmittingTextView, forChat sessionId: UUID) {
        chatComposers[sessionId] = WeakTextView(view)
        if pendingComposerFocus == sessionId {
            pendingComposerFocus = nil
            focusWhenWindowed(view)
        }
    }

    func registerTranscript(_ view: NSView, forChat sessionId: UUID) {
        chatTranscripts[sessionId] = WeakNSView(view)
    }

    /// Registers a question picker's key anchor and gives it the keyboard
    /// through the same makeFirstResponder-with-retry path the composer
    /// uses (a lone SwiftUI FocusState write is dropped during the composer
    /// card's animated swap). Unlike composer registration — which never
    /// takes focus, because N panes mount in arbitrary order — a picker
    /// mounting means a question just arrived (or a parked intent targets
    /// this chat), so it grabs focus. Politely: it inherits focus its own
    /// chat's composer held (that composer is mid-teardown) or that nobody
    /// held, but never steals from a terminal or another chat's editor.
    func registerQuestionPicker(_ view: NSView, forChat sessionId: UUID) {
        chatQuestionPickers[sessionId] = WeakNSView(view)
        if pendingComposerFocus == sessionId {
            pendingComposerFocus = nil
            focusWhenWindowed(view)
            return
        }
        // A parked intent for ANOTHER chat outranks this mount's grab.
        guard pendingComposerFocus == nil else { return }
        focusWhenWindowed(view) { [weak self] window in
            self?.questionPickerMayTakeFocus(in: window, forChat: sessionId) ?? false
        }
    }

    /// The picker is leaving its window (question resolved/dismissed, or
    /// the whole chat unmounting). If the picker area held the keyboard,
    /// hand it to the composer that replaces it — parking the intent until
    /// the (remounting) composer registers.
    func unregisterQuestionPicker(_ view: NSView, forChat sessionId: UUID) {
        guard chatQuestionPickers[sessionId]?.view === view else { return }
        chatQuestionPickers[sessionId] = nil
        guard let window = view.window else { return }
        let responder = window.firstResponder
        let pickerHeldFocus = responder === view
            // Teardown ordering may already have dropped focus to the
            // window — nobody owns it, the returning composer may claim it.
            || responder === window
            || isQuestionPickerNotesEditor(responder)
        if pickerHeldFocus {
            requestComposerFocus(forChat: sessionId)
        }
    }

    /// The picker's notes editor is a SubmittingTextView too; recognize it
    /// as "inside the picker" by exclusion — editable, but registered as no
    /// chat's composer.
    private func isQuestionPickerNotesEditor(_ responder: NSResponder?) -> Bool {
        guard let textView = responder as? SubmittingTextView else { return false }
        if textView === composerTextView { return false }
        return !chatComposers.values.contains { $0.view === textView }
    }

    /// Whether a newly mounted picker may take the keyboard: yes when its
    /// own chat's composer holds it (the picker replaces that composer) or
    /// when nobody meaningful does; no while the user is typing elsewhere —
    /// a terminal, another chat's composer/picker, any editable field.
    private func questionPickerMayTakeFocus(in window: NSWindow, forChat sessionId: UUID) -> Bool {
        guard window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        guard let responder = window.firstResponder, responder !== window else { return true }
        if responder is Ghostty.SurfaceView { return false }
        if let anchor = responder as? NSView,
           chatQuestionPickers.contains(where: { $0.key != sessionId && $0.value.view === anchor }) {
            return false
        }
        if let textView = responder as? NSTextView, textView.isEditable {
            return textView === chatComposers[sessionId]?.view
        }
        if let field = responder as? NSTextField, field.isEditable { return false }
        return true
    }

    /// The chat's composer-area keyboard surface: its question picker while
    /// a blocking question is up (the composer is unmounted then), else its
    /// composer text view.
    private func composerAreaView(forChat sessionId: UUID) -> NSView? {
        if let picker = chatQuestionPickers[sessionId]?.view { return picker }
        return chatComposers[sessionId]?.view
    }

    /// The unkeyed picker fallback, mirroring the single-slot
    /// `composerTextView`: only unambiguous when exactly one picker is live.
    private var fallbackQuestionPicker: NSView? {
        let live = chatQuestionPickers.values.compactMap(\.view)
        return live.count == 1 ? live[0] : nil
    }

    /// Focuses a specific chat's composer area — immediately when possible,
    /// otherwise the moment it registers (see `pendingComposerFocus`).
    func requestComposerFocus(forChat sessionId: UUID) {
        if let view = composerAreaView(forChat: sessionId) {
            focusWhenWindowed(view)
        } else {
            pendingComposerFocus = sessionId
        }
    }

    /// Views register from makeNSView, BEFORE they are attached to a
    /// window — and makeFirstResponder needs the window. Retry briefly
    /// until attachment (the same trick the terminal's Ghostty.moveFocus
    /// uses); a view that never lands in a window just times out. An
    /// optional gate is re-evaluated at grab time (not schedule time) so
    /// polite grabs judge the settled responder.
    private func focusWhenWindowed(
        _ view: NSView,
        attempts: Int = 20,
        given shouldFocus: ((NSWindow) -> Bool)? = nil
    ) {
        if let window = view.window {
            if shouldFocus?(window) ?? true {
                window.makeFirstResponder(view)
            }
            return
        }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
            guard let self, let view else { return }
            self.focusWhenWindowed(view, attempts: attempts - 1, given: shouldFocus)
        }
    }

    /// Focuses the ACTIVE group's selected chat's composer area when there
    /// is one; otherwise the last-registered composer (drafts, single-chat
    /// screens, the new-chat page) or, with the composer slot dead behind a
    /// question, the live picker.
    func focusComposer() {
        if let chatId = centerGroup?.state.selectedPane?.chatSessionId,
           let view = composerAreaView(forChat: chatId) {
            view.window?.makeFirstResponder(view)
            return
        }
        guard let view = (composerTextView as NSView?) ?? fallbackQuestionPicker else { return }
        view.window?.makeFirstResponder(view)
    }

    func focusTerminal() {
        paneGroup?.focusSelectedPane()
    }

    /// Gives a passive pane (currently New Tab) neutral keyboard focus. The
    /// window becomes its own first responder, which cleanly resigns a hidden
    /// terminal or editor without routing keys into an unrelated chat.
    func focusPaneBackground() {
        guard let window = hostWindow,
              window.isKeyWindow,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return }
        window.makeFirstResponder(nil)
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
            case .keyDown:
                if self.handleTabCommand(event) { return nil }
                return self.handleTypeToFocus(event)
            case .leftMouseDown: return self.handleTranscriptClick(event)
            default: return event
            }
        }
    }

    /// Tab commands while the chat (or anything that isn't a terminal) holds
    /// focus, acting on the center group — the same shortcuts a focused
    /// terminal routes to its own group via its key-equivalent handler
    /// (GhosttyTerminalSurfaceAdapter), whose matching this mirrors.
    private func handleTabCommand(_ event: NSEvent) -> Bool {
        guard let centerGroup,
              let window = hostWindow ?? composerTextView?.window,
              event.window === window,
              window.isKeyWindow,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil,
              // Focused terminals (either group) route their own commands.
              !(window.firstResponder is Ghostty.SurfaceView)
        else { return false }
        // Arrow keys carry implicit .function/.numericPad flags — strip them
        // or the exact-modifier comparisons below never match.
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])
        if mods == [.command, .option] {
            if event.specialKey == .leftArrow {
                centerGroup.handleCommand(.previousTab)
                return true
            }
            if event.specialKey == .rightArrow {
                centerGroup.handleCommand(.nextTab)
                return true
            }
        }
        if mods == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "t" {
                centerGroup.handleCommand(.newTab)
                return true
            }
            if chars == "w" {
                if let selected = centerGroup.state.selectedPane,
                   centerGroup.canClose(id: selected.id) {
                    centerGroup.handleCommand(.closeTab)
                    return true
                }
                // The selected tab can't close (the anchoring chat) — but
                // while OTHER tabs are open anywhere in the workspace, ⌘W
                // must not fall through to Close Window; it just no-ops.
                // Only on the last tab does ⌘W become the window's.
                return hasOtherCenterTabs?() ?? false
            }
            if chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
                centerGroup.handleCommand(.selectTab(digit - 1))
                return true
            }
        }
        return false
    }

    func stopTypeToFocus() {
        guard let typeToFocusMonitor else { return }
        NSEvent.removeMonitor(typeToFocusMonitor)
        self.typeToFocusMonitor = nil
    }

    private func handleTypeToFocus(_ event: NSEvent) -> NSEvent? {
        // The chat unmounts while a terminal tab covers it, so a stale
        // target reference (or one detached from the window) naturally
        // opts out here — no explicit visibility flag needed.
        guard let target = typeToFocusTarget(),
              let window = target.window,
              event.window === window,
              window.isKeyWindow,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil,
              window.firstResponder !== target,
              Self.isTypeToFocusEvent(
                  event,
                  includesQuestionPickerCommands: target is QuestionPickerKeyView
              ) else {
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
        // A focused question picker owns its keys (digits select options,
        // space toggles) — never pull them away to another chat's composer.
        if let responder = window.firstResponder as? NSView,
           chatQuestionPickers.values.contains(where: { $0.view === responder }) {
            return event
        }

        guard window.makeFirstResponder(target) else { return event }

        // Local monitors run before NSApplication.sendEvent. Returning the
        // original event dispatches it to the new first responder, preserving
        // NSTextView's native key binding, undo, dead-key, and IME pipelines.
        return event
    }

    /// The composer-area typing target: the selected chat's picker anchor
    /// while a question is up (the composer is unmounted then — stray
    /// typing self-heals focus onto the picker, so digits land as option
    /// picks even if the mount-time grab ever races the swap), otherwise
    /// the editable composer text view.
    private func typeToFocusTarget() -> NSView? {
        if let selectedPane = centerGroup?.state.selectedPane {
            // A terminal or New Tab page must never route typing into some
            // other, merely mounted chat. An unkeyed chat is the legacy/draft
            // case and still uses the single-slot fallback below.
            guard selectedPane.kind == .chat else { return nil }
            if let chatId = selectedPane.chatSessionId {
                if let picker = chatQuestionPickers[chatId]?.view {
                    return picker
                }
                if let textView = chatComposers[chatId]?.view, textView.isEditable {
                    return textView
                }
                return nil
            }
        }
        if let textView = composerTextView, textView.isEditable {
            return textView
        }
        return fallbackQuestionPicker
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
        // Every registered chat transcript is a click-into-the-chat zone
        // (multi-chat workspaces have several); the single slot is the
        // fallback for screens that never register keyed (the new-chat
        // page). A click that lands in a zone parks focus on THAT transcript
        // unless the click itself claimed focus. Printable typing then hands
        // off to the keyed composer through handleTypeToFocus.
        var zones: [(chatId: UUID?, view: NSView)] = chatTranscripts.compactMap { id, box in
            box.view.map { (id, $0) }
        }
        if let transcriptView, !zones.contains(where: { $0.view === transcriptView }) {
            zones.append((nil, transcriptView))
        }
        for zone in zones {
            guard let window = zone.view.window,
                  event.window === window,
                  window.attachedSheet == nil,
                  NSApp.modalWindow == nil,
                  let zoneSuperview = zone.view.superview else { continue }
            // Geometry check scoped to the zone's own subtree (hitTest
            // takes superview coordinates). Overlays floating inside its
            // frame — the composer card, scroll-to-bottom — are excluded
            // by the focus-change check below, not by geometry.
            let point = zoneSuperview.convert(event.locationInWindow, from: nil)
            guard let hitView = zone.view.hitTest(point) else { continue }

            let responderBeforeClick = window.firstResponder
            if let composer = zone.chatId.flatMap({ chatComposers[$0]?.view }),
               responderBeforeClick === composer {
                return event // Already writing in this chat.
            }

            DispatchQueue.main.async {
                // Someone claimed focus from this click (text selection, a
                // menu, a control): leave it alone.
                guard window.firstResponder === responderBeforeClick else { return }

                // Clicking or dragging again in an already-focused text view
                // leaves the same first responder in place. Treat the hit
                // view as the evidence in that case; moving focus to the
                // transcript would end native selection tracking and clear
                // TranscriptSelectableTextView's selected range.
                if let responderView = responderBeforeClick as? NSView,
                   hitView === responderView || hitView.isDescendant(of: responderView) {
                    return
                }

                // Inert history chrome and whitespace do not claim AppKit
                // focus themselves. Park focus on the transcript so its chat
                // becomes active without implying composer focus.
                window.makeFirstResponder(zone.view)
            }
            return event
        }
        return event
    }

    private static func isTypeToFocusEvent(
        _ event: NSEvent,
        includesQuestionPickerCommands: Bool = false
    ) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)

        if includesQuestionPickerCommands {
            // Arrow keys carry implicit function/numpad flags. After removing
            // those, picker commands must be genuinely unmodified.
            let pickerModifiers = modifiers.subtracting([.function, .numericPad])
            if pickerModifiers.isEmpty {
                switch event.specialKey {
                case .upArrow, .downArrow, .leftArrow, .rightArrow:
                    return true
                default:
                    break
                }
                // Return, keypad Enter, Escape, and Space operate the picker.
                if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53
                    || event.charactersIgnoringModifiers == " " {
                    return true
                }
            }
        }

        guard modifiers.intersection([.command, .control, .function]).isEmpty,
              event.specialKey == nil else { return false }

        // Keep Space available for scrolling and Full Keyboard Access button
        // activation when the ordinary composer is not focused. A question
        // picker's Space is handled above because it toggles the highlighted
        // option. Option is deliberately allowed because it produces text on
        // many keyboard layouts; dead-key events may have no characters and
        // still need to reach NSTextView.
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
        Button("Toggle Bottom Panel") { action?.toggle() }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(action == nil)
    }
}
