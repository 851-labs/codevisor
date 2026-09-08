#if os(macOS)
  import AppKit
  import CodevisorTestSupport
  import SwiftUI
  import Testing
  @testable import CodevisorUI

  @MainActor
  private final class BrowserFocusWindow: NSWindow {
    let changed = TestSignal()
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
      let accepted = super.makeFirstResponder(responder)
      changed.signal()
      return accepted
    }
    func waitForEditor() async {
      while !(firstResponder is NSTextView) {
        let next = changed.value + 1
        await changed.wait(for: next)
      }
    }
  }

  @MainActor
  @Suite("Native browser address editing")
  struct BrowserAddressEditorTests {
    private func field(in view: NSView) -> NSTextField? {
      if let field = view as? NSTextField { return field }
      return view.subviews.lazy.compactMap { field(in: $0) }.first
    }

    @Test(arguments: [false, true])
    func clickAndLocationCommandSelectTheFullURLBeforeTyping(command: Bool) async throws {
      _ = NSApplication.shared
      let window = BrowserFocusWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 44),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      var text = "example.com"
      var editing = command
      let full = "https://example.com/path?query=" + String(repeating: "long-address-value-", count: 20)
      let suggestions = BrowserSuggestions(profile: "test", history: BrowserHistory(defaults: nil), fetch: { _ in [] })
      defer {
        suggestions.dismiss()
        window.childWindows?.forEach { $0.close() }
        window.contentView = nil
        window.close()
      }
      window.contentView = NSHostingView(
        rootView: BrowserAddressEditor(
          text: Binding(get: { text }, set: { text = $0 }),
          editing: Binding(get: { editing }, set: { editing = $0 }),
          focusRequest: command ? 1 : 0, fullAddress: full, suggestions: suggestions,
          submit: { _ in }, cancel: {}))
      window.contentView?.layoutSubtreeIfNeeded()
      let field = try #require(window.contentView.flatMap { self.field(in: $0) })
      if command {
        await window.waitForEditor()
      } else {
        let click = try #require(
          NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        field.mouseDown(with: click)
      }
      let editor = try #require(field.currentEditor() as? NSTextView)
      #expect(editing)
      #expect(field.stringValue == full)
      #expect(editor.selectedRange() == NSRange(location: 0, length: (full as NSString).length))
      let layout = try #require(editor.layoutManager)
      let container = try #require(editor.textContainer)
      layout.ensureLayout(for: container)
      var lineCount = 0
      layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) {
        _, _, _, _, _ in lineCount += 1
      }
      #expect(lineCount == 1, "Long addresses scroll horizontally instead of wrapping inside the toolbar")
      editor.insertText("swift", replacementRange: editor.selectedRange())
      #expect(text == "swift")
      #expect(field.stringValue == "swift")
      #expect(field.currentEditor() === editor)
      #expect(suggestions.query == "swift")

      let coordinator = try #require(field.delegate as? BrowserAddressEditor.Coordinator)
      editor.setSelectedRange(NSRange(location: 5, length: 0))
      coordinator.focusAndSelectAll()
      #expect(editing, "Repeating Open Location must not end editing")
      #expect(field.currentEditor() === editor)
      #expect(field.stringValue == "swift", "Open Location preserves an unsubmitted draft")
      #expect(editor.selectedRange() == NSRange(location: 0, length: 5))
      coordinator.focusAndSelectAll()
      #expect(editor.selectedRange() == NSRange(location: 0, length: 5))
    }
  }
#endif
