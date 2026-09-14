import AppKit
import Autocomplete
import SwiftUI
import Testing
@testable import ComposerSurface

@Suite("Composer picker keyboard ownership")
@MainActor
struct ComposerPickerKeyboardTests {
  @Test("Return reaches the open picker's highlighted footer instead of toggling the trigger")
  func footerReturn() throws {
    _ = NSApplication.shared
    var activations = 0
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = NSHostingView(
      rootView: Autocomplete.Suggestions(query: .constant("missing")) {
        Autocomplete.Action("Model") { Issue.record("Unmatched model selected") }
        Autocomplete.Footer(id: "manage") {
          Autocomplete.Action("Manage Harnesses…") { activations += 1 }
        }
      }
      .composerKeyboardButton(isPresenting: true) { Issue.record("Picker trigger intercepted Return") }
      .environment(\.locale, Locale(identifier: "en_US_POSIX")))
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    let field = try #require(searchField(in: view))
    #expect(window.makeFirstResponder(field))
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      window.sendEvent(
        try #require(
          NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
    }
    #expect(activations == 1)
  }

  private func searchField(in view: NSView) -> NSSearchField? {
    if let field = view as? NSSearchField { return field }
    return view.subviews.lazy.compactMap { searchField(in: $0) }.first
  }
}
