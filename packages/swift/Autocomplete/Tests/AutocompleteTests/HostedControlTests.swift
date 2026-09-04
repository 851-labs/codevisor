#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import Testing
  @testable import Autocomplete

  @Suite("Autocomplete hosted controls", .serialized)
  @MainActor
  struct HostedControlTests {
    private func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }
    private func field(in view: NSView) -> NSSearchField? {
      if let field = view as? NSSearchField { return field }
      return view.subviews.lazy.compactMap { field(in: $0) }.first
    }
    private func window(_ root: some View) -> NSWindow {
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 250),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: AnyView(root))
      window.contentView?.layoutSubtreeIfNeeded()
      drain()
      return window
    }

    @Test("An inherited SwiftUI disabled environment prevents Return from invoking a row")
    func inheritedDisabled() {
      var accepted = 0
      let window = window(
        Autocomplete.Suggestions {
          Autocomplete.Action("Match") { accepted += 1 }
        }.disabled(true))
      defer { window.contentView = nil; drain() }
      guard let view = window.contentView, let field = field(in: view),
        let coordinator = field.delegate as? Autocomplete.InputField.Coordinator
      else { Issue.record("Search field did not mount"); return }
      #expect(!field.isEnabled)
      #expect(
        !coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
      drain()
      #expect(accepted == 0)
    }

    @Test("Enabled hosted controls route Return through their current semantic action")
    func enabledReturn() {
      var accepted = 0
      let window = window(Autocomplete.Suggestions { Autocomplete.Action("Match") { accepted += 1 } })
      defer { window.contentView = nil; drain() }
      guard let view = window.contentView, let field = field(in: view),
        let coordinator = field.delegate as? Autocomplete.InputField.Coordinator
      else { Issue.record("Search field did not mount"); return }
      #expect(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
      #expect(accepted == 1)
    }

    @Test("Native search layout updates its font and icon columns in place")
    func inputConfiguration() {
      var metrics = Autocomplete.Metrics()
      let container = Autocomplete.InputCapsuleView(metrics: metrics, showsCheckmarks: false, showsIcons: false)
      let field = container.searchField
      metrics.fontSize = 22
      metrics.inputHeight = 40
      container.configure(metrics: metrics, showsCheckmarks: true, showsIcons: true)
      #expect(container.searchField === field)
      #expect(field.font?.pointSize == 22)
      #expect(container.intrinsicContentSize.height == 40)
      container.userInterfaceLayoutDirection = .rightToLeft
      container.configure(metrics: metrics, showsCheckmarks: false, showsIcons: true)
      #expect(container.userInterfaceLayoutDirection == .rightToLeft)
    }

    @Test("An early focus request remains pending until attachment")
    func pendingFocus() {
      _ = NSApplication.shared
      let container = Autocomplete.InputCapsuleView(metrics: .xcodeMenu, showsCheckmarks: false, showsIcons: false)
      var focused = false
      container.requestFocus = { [weak container] in
        guard let container, let window = container.window else { return }
        focused = window.makeFirstResponder(container.searchField)
        if focused { container.requestFocus = nil }
      }
      container.requestFocus?()
      #expect(!focused)
      #expect(container.requestFocus != nil)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 280, height: 50),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = container
      drain()
      #expect(focused)
      #expect(container.requestFocus == nil)
      window.contentView = nil
    }

    @Test("The native field handles a favorite key equivalent once without selecting or dismissing")
    func favoriteKeyEquivalent() {
      let selection = SelectionStore("Other")
      let favorites = SelectionStore<[String]>([])
      let window = window(
        Autocomplete.Suggestions {
          Autocomplete.Picker("Projects", selection: selection.binding) {
            Autocomplete.Choice("Demo", value: "Demo")
          }.favorites(favorites.binding)
        })
      defer { window.contentView = nil; drain() }
      guard let view = window.contentView, let field = field(in: view) else {
        Issue.record("Search field did not mount"); return
      }
      #expect(window.makeFirstResponder(field))
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "F",
        charactersIgnoringModifiers: "F", isARepeat: false, keyCode: 3)!
      #expect(field.performKeyEquivalent(with: event))
      #expect(favorites.value == ["Demo"])
      #expect(selection.value == "Other")
      drain()
      #expect(field.performKeyEquivalent(with: event))
      #expect(favorites.value.isEmpty)
      #expect(selection.value == "Other")
      let editor = window.firstResponder as! NSTextView
      editor.setMarkedText(
        "ni", selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(!(field as! Autocomplete.SearchField).onKeyEquivalent(event))
      #expect(favorites.value.isEmpty)
    }

    @Test("Tab reaches the highlighted favorite and Space toggles it without selecting")
    func keyboardFavoriteFocus() async {
      let selection = SelectionStore("Other")
      let favorites = SelectionStore<[String]>([])
      let window = window(
        Autocomplete.Suggestions {
          Autocomplete.Picker("Projects", selection: selection.binding) {
            Autocomplete.Choice("Demo", value: "Demo")
          }.favorites(favorites.binding)
        })
      defer { window.contentView = nil; drain() }
      guard let view = window.contentView, let field = field(in: view),
        let coordinator = field.delegate as? Autocomplete.InputField.Coordinator
      else { Issue.record("Search field did not mount"); return }
      #expect(window.makeFirstResponder(field))
      #expect(
        coordinator.control(
          field, textView: window.firstResponder as! NSTextView,
          doCommandBy: #selector(NSResponder.insertTab(_:))))
      try? await Task.sleep(for: .milliseconds(100))
      #expect((window.firstResponder as? NSTextView)?.delegate !== field)
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        window.sendEvent(
          NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49)!)
      }
      try? await Task.sleep(for: .milliseconds(100))
      #expect(favorites.value == ["Demo"])
      #expect(selection.value == "Other")
    }

    @Test("A focus binding can focus, relinquish, and refocus an attached field")
    func focusBinding() async {
      var focused: Binding<Bool>!
      let window = window(FocusFixture { focused = $0 })
      defer { window.contentView = nil; drain() }
      guard let view = window.contentView, let field = field(in: view) else {
        Issue.record("Search field did not mount"); return
      }
      func isEditing() -> Bool {
        return (window.firstResponder as? NSTextView)?.delegate === field
      }
      #expect(!isEditing())
      focused.wrappedValue = true
      window.contentView?.layoutSubtreeIfNeeded()
      try? await Task.sleep(for: .milliseconds(100))
      #expect(isEditing())
      focused.wrappedValue = false
      window.contentView?.layoutSubtreeIfNeeded()
      try? await Task.sleep(for: .milliseconds(100))
      #expect(!isEditing())
      focused.wrappedValue = true
      window.contentView?.layoutSubtreeIfNeeded()
      try? await Task.sleep(for: .milliseconds(100))
      #expect(isEditing())
    }

    private struct FocusFixture: View {
      @State private var focused = false
      let capture: (Binding<Bool>) -> Void
      var body: some View {
        Autocomplete.Suggestions { Autocomplete.Action("Match") {} }
          .autocompleteSearchFocused($focused)
          .onAppear { capture($focused) }
      }
    }

    @Test("Only a visually bottom-aligned final row receives concentric corners")
    func bottomCorners() {
      let coordinateSpace = UUID()
      let edge = Autocomplete.BottomEdge(isLast: true, height: 300, inset: 4, coordinateSpace: coordinateSpace)
      #expect(edge.contains(bottom: 296))
      #expect(edge.contains(bottom: 295.5))
      #expect(!edge.contains(bottom: 88))
      #expect(!edge.contains(bottom: 320))
      #expect(
        !Autocomplete.BottomEdge(isLast: false, height: 300, inset: 4, coordinateSpace: coordinateSpace).contains(
          bottom: 296))
      #expect(
        !Autocomplete.BottomEdge(isLast: true, height: 0, inset: 4, coordinateSpace: coordinateSpace).contains(
          bottom: -4))
    }

    @Test("Small layout bounds never produce negative heights")
    func constrainedSize() {
      var metrics = Autocomplete.Metrics()
      metrics.maximumHeight = 8
      #expect(metrics.listHeight(itemCount: 10) == 0)
    }
  }
#endif
