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
      await changed.cancellableWait { firstResponder is NSTextView }
    }
  }

  @MainActor
  private final class AddressEditorFixture {
    static let full = "https://example.com/path?query=" + String(repeating: "long-address-value-", count: 20)
    var text = "example.com"
    var editing: Bool
    let window = BrowserFocusWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 44),
      styleMask: .borderless, backing: .buffered, defer: false)
    let suggestions = BrowserSuggestions(profile: "test", history: BrowserHistory(defaults: nil), fetch: { _ in [] })
    private(set) var field: NSTextField?

    init(command: Bool) {
      _ = NSApplication.shared
      editing = command
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: BrowserAddressEditor(
          text: Binding(get: { self.text }, set: { self.text = $0 }),
          editing: Binding(get: { self.editing }, set: { self.editing = $0 }),
          focusRequest: command ? 1 : 0, fullAddress: Self.full, suggestions: suggestions,
          submit: { _ in }, cancel: {}))
      window.contentView?.layoutSubtreeIfNeeded()
      field = window.contentView.flatMap(Self.field(in:))
    }

    private static func field(in view: NSView) -> NSTextField? {
      if let field = view as? NSTextField { return field }
      return view.subviews.lazy.compactMap { field(in: $0) }.first
    }

    func send(_ type: NSEvent.EventType, x: CGFloat) throws {
      let field = try #require(field)
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: field.convert(NSPoint(x: x, y: field.bounds.midY), to: nil),
          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
          clickCount: 1, pressure: 1))
      switch type {
      case .leftMouseDown:
        #expect(window.makeFirstResponder(field))
        field.mouseDown(with: event)
      case .leftMouseDragged: field.mouseDragged(with: event)
      default: field.mouseUp(with: event)
      }
    }

    func close() {
      suggestions.dismiss()
      window.childWindows?.forEach { $0.close() }
      window.contentView = nil
      window.close()
    }
  }

  @MainActor
  @Suite("Native browser address editing", .timeLimit(.minutes(1)))
  struct BrowserAddressEditorTests {
    @Test(arguments: [false, true])
    func clickAndLocationCommandSelectTheFullURLBeforeTyping(command: Bool) async throws {
      let fixture = AddressEditorFixture(command: command)
      defer { fixture.close() }
      let field = try #require(fixture.field)
      let full = AddressEditorFixture.full
      if command {
        await fixture.window.waitForEditor()
      } else {
        try fixture.send(.leftMouseDown, x: field.bounds.maxX - 1)
        try fixture.send(.leftMouseUp, x: field.bounds.maxX - 1)
      }
      let editor = try #require(field.currentEditor() as? NSTextView)
      #expect(fixture.editing)
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
      #expect(fixture.text == "swift")
      #expect(field.stringValue == "swift")
      #expect(field.currentEditor() === editor)
      #expect(fixture.suggestions.query == "swift")

      let coordinator = try #require(field.delegate as? BrowserAddressEditor.Coordinator)
      editor.setSelectedRange(NSRange(location: 5, length: 0))
      coordinator.focusAndSelectAll()
      #expect(fixture.editing, "Repeating Open Location must not end editing")
      #expect(field.currentEditor() === editor)
      #expect(field.stringValue == "swift", "Open Location preserves an unsubmitted draft")
      #expect(editor.selectedRange() == NSRange(location: 0, length: 5))
      coordinator.focusAndSelectAll()
      #expect(editor.selectedRange() == NSRange(location: 0, length: 5))
    }

    @Test func draggingFromTheFocusingClickSelectsOnlyTheDraggedText() throws {
      let fixture = AddressEditorFixture(command: false)
      defer { fixture.close() }
      try fixture.send(.leftMouseDown, x: 0)
      try fixture.send(.leftMouseDragged, x: 120)
      try fixture.send(.leftMouseUp, x: 120)
      let selection = try #require(fixture.field?.currentEditor()).selectedRange
      #expect(selection.location == 0)
      #expect(selection.length > 0)
      #expect(selection.length < (AddressEditorFixture.full as NSString).length)
    }
  }
#endif
