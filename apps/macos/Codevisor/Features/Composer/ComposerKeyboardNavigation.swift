import AppKit

/// Routes typing from a focused composer control through the editor's native
/// input pipeline. Only focused controls install a listener; menus and other
/// windows retain their own keyboard handling.
final class ComposerControlTypingFocus {
  weak var editor: NSTextView?
  private var focusedControls: Set<UUID> = []
  private var monitor: Any?

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
  }

  func setControlFocused(_ focused: Bool, id: UUID) {
    if focused {
      focusedControls.insert(id)
      if monitor == nil {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
          guard let self else { return event }
          return self.handleKeyDown(event)
        }
      }
    } else {
      focusedControls.remove(id)
      if focusedControls.isEmpty, let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
    }
  }

  func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    guard !focusedControls.isEmpty,
      let editor, editor.isEditable,
      let window = editor.window, event.window === window,
      window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
      window.firstResponder !== editor,
      ComposerKeyboardNavigation.isTypingEvent(event)
    else { return event }
    // Search fields and editable popover content own their input even while
    // SwiftUI still reports focus on the control that opened them.
    if let text = window.firstResponder as? NSTextView, text.isEditable { return event }
    if let field = window.firstResponder as? NSTextField, field.isEditable { return event }
    guard window.makeFirstResponder(editor) else { return event }
    editor.keyDown(with: event)
    return nil
  }
}

/// A neutral focus destination at the editor's position in the key-view
/// loop. Escape removes the caret; the next Tab starts after the editor,
/// so the composer toolbar can be reached without inserting a tab in the draft.
final class ComposerNavigationScrollView: NSScrollView {
  override var acceptsFirstResponder: Bool { true }
  // NSScrollView normally forwards focus straight into its document view.
  override func becomeFirstResponder() -> Bool { true }
  // Only Escape targets this view. Ordinary Tab navigation visits the
  // editor and controls, without adding a second stop for the scroll view.
  override var canBecomeKeyView: Bool { false }

  @discardableResult
  func releaseEditorFocus() -> Bool {
    guard let window, window.firstResponder === documentView else { return false }
    return window.makeFirstResponder(self)
  }

  override func keyDown(with event: NSEvent) {
    guard let editor = documentView as? NSTextView, let window else {
      super.keyDown(with: event)
      return
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 48, modifiers.subtracting([.shift, .capsLock]).isEmpty {
      if modifiers.contains(.shift) {
        window.selectKeyView(preceding: editor)
      } else {
        window.selectKeyView(following: editor)
      }
      return
    }
    if editor.isEditable, ComposerKeyboardNavigation.isTypingEvent(event), window.makeFirstResponder(editor) {
      // Forward the original key through TextKit so the first character,
      // selection replacement, undo, and dead keys all behave like typing.
      editor.keyDown(with: event)
      return
    }
    // A second Escape stays neutral instead of reaching window dismissal.
    if event.keyCode == 53 { return }
    super.keyDown(with: event)
  }
}

enum ComposerKeyboardNavigation {
  static func isTypingEvent(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard modifiers.intersection([.command, .control, .function]).isEmpty,
      event.specialKey == nil
    else { return false }
    if let characters = event.characters, characters.rangeOfCharacter(from: .alphanumerics) != nil {
      return true
    }
    // Option-letter dead keys can have no composed character yet. Hand
    // them to the native input method, without treating punctuation or
    // Space (which activates focused buttons) as a request to start writing.
    return modifiers.contains(.option)
      && event.charactersIgnoringModifiers?.rangeOfCharacter(from: .alphanumerics) != nil
  }

  static func canResumeTyping(from responder: NSResponder?, editor: NSView, transcript: NSView?) -> Bool {
    guard let view = responder as? NSView else { return false }
    if let text = view as? NSTextView, text.isEditable { return false }
    if let field = view as? NSTextField, field.isEditable { return false }
    if let scroll = editor.enclosingScrollView as? ComposerNavigationScrollView, view === scroll { return true }
    guard let transcript else { return false }
    // Interactive controls own their letters (e.g. menu typeahead). Only
    // passive transcript surfaces resume typing into the composer.
    return view === transcript || (view is NSTextView && view.isDescendant(of: transcript))
  }
}
