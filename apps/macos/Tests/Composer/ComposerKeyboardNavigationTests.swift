import AppKit
import Autocomplete
import CodevisorUI
import SwiftUI
import Testing
@testable import ComposerSurface

@Suite("Composer keyboard navigation")
@MainActor
struct ComposerKeyboardNavigationTests {
  private func event(
    _ key: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow,
    type: NSEvent.EventType = .keyDown
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: key,
      charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
  }

  private func fixture() -> (NSWindow, ComposerNavigationScrollView, SubmittingTextView, NSButton) {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.autorecalculatesKeyViewLoop = false
    let scroll = ComposerNavigationScrollView(frame: NSRect(x: 0, y: 60, width: 500, height: 120))
    let editor = SubmittingTextView(frame: scroll.bounds)
    editor.isRichText = false
    editor.allowsUndo = true
    scroll.documentView = editor
    let button = KeyboardButton(title: "Attach", target: nil, action: nil)
    button.frame = NSRect(x: 0, y: 10, width: 100, height: 30)
    window.contentView?.addSubview(scroll)
    window.contentView?.addSubview(button)
    editor.nextKeyView = button
    button.nextKeyView = editor
    window.makeFirstResponder(editor)
    return (window, scroll, editor, button)
  }

  @Test("Escape leaves the draft intact, then Tab reaches controls and Shift-Tab returns to the editor")
  func escapeThenTab() {
    let (window, scroll, editor, button) = fixture()
    defer { window.close() }
    editor.string = "Keep this draft"
    editor.setSelectedRange(NSRange(location: 5, length: 4))
    editor.keyDown(with: event("\u{1b}", code: 53, window: window))
    #expect(window.firstResponder === scroll)
    #expect(editor.string == "Keep this draft")
    #expect(editor.selectedRange() == NSRange(location: 5, length: 4))
    scroll.keyDown(with: event("\u{1b}", code: 53, window: window))
    #expect(window.firstResponder === scroll)
    scroll.keyDown(with: event("\t", code: 48, window: window))
    #expect(window.firstResponder === button)
    window.selectPreviousKeyView(nil)
    #expect(window.firstResponder === editor)
    #expect(editor.string == "Keep this draft")
  }

  @Test("Escape dismisses an active composer command before leaving the editor")
  func dismissPaletteFirst() {
    let (window, scroll, editor, _) = fixture()
    defer { window.close() }
    var paletteOpen = true
    editor.onKeyCommand = { command in
      guard command == .dismissSelection, paletteOpen else { return false }
      paletteOpen = false
      return true
    }
    editor.keyDown(with: event("\u{1b}", code: 53, window: window))
    #expect(!paletteOpen)
    #expect(window.firstResponder === editor)
    editor.keyDown(with: event("\u{1b}", code: 53, window: window))
    #expect(window.firstResponder === scroll)
  }

  @Test("Typing after Escape preserves the first character, selection replacement, and undo")
  func resumeTyping() {
    let (window, scroll, editor, _) = fixture()
    defer { window.close() }
    editor.string = "hello"
    editor.setSelectedRange(NSRange(location: 4, length: 1))
    editor.keyDown(with: event("\u{1b}", code: 53, window: window))
    scroll.keyDown(with: event("A", code: 0, modifiers: .shift, window: window))
    #expect(window.firstResponder === editor)
    #expect(editor.string == "hellA")
    editor.undoManager?.undo()
    #expect(editor.string == "hello")
  }

  @Test("Space stays outside the draft and disabled composers cannot resume typing")
  func neutralAndDisabledInput() {
    let (window, scroll, editor, _) = fixture()
    defer { window.close() }
    editor.string = "draft"
    editor.keyDown(with: event("\u{1b}", code: 53, window: window))
    scroll.keyDown(with: event(" ", code: 49, window: window))
    #expect(window.firstResponder === scroll)
    #expect(editor.string == "draft")
    editor.isEditable = false
    scroll.keyDown(with: event("a", code: 0, window: window))
    #expect(window.firstResponder === scroll)
    #expect(editor.string == "draft")
  }

  @Test("Marked text gets Escape before the composer does")
  func composingText() {
    let (window, _, editor, _) = fixture()
    defer { window.close() }
    var dismissed = false
    editor.onKeyCommand = { _ in
      dismissed = true; return true
    }
    editor.setMarkedText(
      "ni", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.keyDown(with: event("\u{1b}", code: 53, window: window))
    #expect(!dismissed)
    #expect(window.firstResponder === editor)
  }

  @Test("Typing activation excludes shortcuts, Space, punctuation, and navigation keys")
  func typingKeys() {
    let (window, _, _, _) = fixture()
    defer { window.close() }
    for key in ["a", "Z", "7", "é", "中"] {
      #expect(ComposerKeyboardNavigation.isTypingEvent(event(key, code: 0, window: window)))
    }
    for key in [" ", "\u{00a0}", "/", ".", "\t", "\r", "\u{1b}"] {
      #expect(!ComposerKeyboardNavigation.isTypingEvent(event(key, code: 0, window: window)))
    }
    for modifiers: NSEvent.ModifierFlags in [.command, .control, .function, [.command, .shift]] {
      #expect(!ComposerKeyboardNavigation.isTypingEvent(event("a", code: 0, modifiers: modifiers, window: window)))
    }
  }

  @Test("Focus can return from this chat's passive surfaces, never another editor or control")
  func typingScope() {
    let (window, scroll, editor, button) = fixture()
    defer { window.close() }
    let transcript = NSView()
    let text = NSTextView()
    text.isEditable = false
    transcript.addSubview(text)
    #expect(ComposerKeyboardNavigation.canResumeTyping(from: scroll, editor: editor, transcript: transcript))
    #expect(ComposerKeyboardNavigation.canResumeTyping(from: text, editor: editor, transcript: transcript))
    text.isEditable = true
    #expect(!ComposerKeyboardNavigation.canResumeTyping(from: text, editor: editor, transcript: transcript))
    #expect(!ComposerKeyboardNavigation.canResumeTyping(from: button, editor: editor, transcript: transcript))
    #expect(!ComposerKeyboardNavigation.canResumeTyping(from: NSView(), editor: editor, transcript: transcript))
    #expect(!ComposerKeyboardNavigation.canResumeTyping(from: window, editor: editor, transcript: transcript))
  }

  @Test(
    "The SwiftUI toolbar participates in Tab navigation and Space activates the focused button",
    arguments: [NSEvent.ModifierFlags(), .capsLock])
  func hostedToolbar(modifiers: NSEvent.ModifierFlags) throws {
    _ = NSApplication.shared
    let state = ToolbarState()
    let window = KeyboardTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: ToolbarFixture(state: state))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let editor = try #require(state.editor)
    #expect(window.makeFirstResponder(editor))
    editor.keyDown(with: event("\u{1b}", code: 53, window: window))
    let scroll = try #require(window.firstResponder as? ComposerNavigationScrollView)
    scroll.keyDown(with: event("\t", code: 48, modifiers: modifiers, window: window))
    #expect(window.firstResponder !== editor)
    #expect(window.firstResponder !== scroll)
    window.sendEvent(event(" ", code: 49, modifiers: modifiers, window: window))
    window.sendEvent(event(" ", code: 49, modifiers: modifiers, window: window, type: .keyUp))
    #expect(state.activated == 1)
    #expect(editor.string.isEmpty)
    window.selectNextKeyView(nil)
    window.sendEvent(event("\r", code: 36, modifiers: modifiers, window: window))
    #expect(state.isMenuOpen)
    state.isMenuOpen = false
    window.selectNextKeyView(nil)
    #expect(window.firstResponder === editor)
    #expect(state.activated == 1)
  }

  @Test(
    "Typing from Attach or the model trigger resumes the draft with the first character",
    arguments: [1, 2], ["a", "7"])
  func typingFromToolbar(tabCount: Int, key: String) throws {
    _ = NSApplication.shared
    let state = ToolbarState()
    let window = KeyboardTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: ToolbarFixture(state: state))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let editor = try #require(state.editor)
    editor.string = "draft"
    editor.setSelectedRange(NSRange(location: 5, length: 0))
    #expect(window.makeFirstResponder(editor))
    editor.keyDown(with: event("\u{1b}", code: 53, window: window))
    let scroll = try #require(window.firstResponder as? ComposerNavigationScrollView)
    scroll.keyDown(with: event("\t", code: 48, window: window))
    if tabCount == 2 { window.selectNextKeyView(nil) }
    host.layoutSubtreeIfNeeded()
    #expect(window.firstResponder !== editor)
    #expect(window.firstResponder !== scroll)
    NSApp.sendEvent(event(key, code: key == "a" ? 0 : 26, window: window))
    #expect(window.firstResponder === editor)
    #expect(editor.string == "draft" + key)
    #expect(state.activated == 0)
    #expect(!state.isMenuOpen)
  }

  @Test("A composer control listener preserves shortcuts, search input, and window boundaries")
  func controlTypingBoundaries() {
    _ = NSApplication.shared
    let window = KeyboardTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let editor = SubmittingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
    let button = KeyboardButton(title: "Model", target: nil, action: nil)
    let search = NSTextView(frame: NSRect(x: 0, y: 80, width: 400, height: 60))
    window.contentView?.addSubview(editor)
    window.contentView?.addSubview(button)
    window.contentView?.addSubview(search)
    let focus = ComposerControlTypingFocus()
    focus.editor = editor
    let controlID = UUID()
    focus.setControlFocused(true, id: controlID)
    defer { focus.setControlFocused(false, id: controlID) }
    #expect(window.makeFirstResponder(button))
    for key in [
      event("a", code: 0, modifiers: .command, window: window),
      event("a", code: 0, modifiers: .control, window: window),
      event(" ", code: 49, window: window),
      event("\r", code: 36, window: window),
    ] {
      #expect(focus.handleKeyDown(key) === key)
      #expect(window.firstResponder === button)
    }
    let key = event("a", code: 0, window: window)
    editor.isEditable = false
    #expect(focus.handleKeyDown(key) === key)
    #expect(window.firstResponder === button)
    editor.isEditable = true
    #expect(window.makeFirstResponder(search))
    #expect(focus.handleKeyDown(key) === key)
    #expect(window.firstResponder === search)
    let (otherWindow, _, _, _) = fixture()
    defer { otherWindow.close() }
    let otherKey = event("a", code: 0, window: otherWindow)
    #expect(window.makeFirstResponder(button))
    #expect(focus.handleKeyDown(otherKey) === otherKey)
    focus.setControlFocused(false, id: controlID)
    #expect(focus.handleKeyDown(key) === key)
    #expect(editor.string.isEmpty)
  }
}

private final class KeyboardButton: NSButton {
  override var acceptsFirstResponder: Bool { true }
}

private final class KeyboardTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}

@MainActor
private final class ToolbarState {
  weak var editor: SubmittingTextView?
  let typingFocus = ComposerControlTypingFocus()
  var activated = 0
  var isMenuOpen = false
}

private struct ToolbarFixture: View {
  let state: ToolbarState
  @State private var text = ""
  @State private var height = ChatInputEditor.singleLineHeight

  var body: some View {
    VStack {
      ChatInputEditor(
        text: $text, calculatedHeight: $height, onSubmit: {},
        onTextViewReady: {
          state.editor = $0
          state.typingFocus.editor = $0
        }
      )
      .frame(height: height)
      HStack {
        Button("Attach") { state.activated += 1 }
          .buttonStyle(HoverIconButtonStyle())
          .composerKeyboardButton { state.activated += 1 }
        Autocomplete.Menu(isPresented: Binding(get: { state.isMenuOpen }, set: { state.isMenuOpen = $0 })) {
          Autocomplete.Action("Test model") {}
        } label: {
          Text("Model")
        }
        .buttonStyle(HoverIconButtonStyle(shape: .chip))
        .composerKeyboardButton(shape: .chip) { state.isMenuOpen.toggle() }
        Button("Disabled send") {}
          .buttonStyle(.plain)
          .composerKeyboardButton { state.activated += 100 }
          .disabled(true)
      }
    }
    .environment(\.composerControlTypingFocus, state.typingFocus)
    .padding()
  }
}
