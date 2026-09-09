#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import Testing
  @testable import Autocomplete

  @Suite("Autocomplete interaction")
  @MainActor
  struct InteractionTests {
    private func configure(
      _ host: Autocomplete.Host, enabled: Bool = true, query: String = "match",
      @Autocomplete.ContentBuilder _ content: () -> [Autocomplete.Entry]
    ) -> Autocomplete.Snapshot {
      let snapshot = Autocomplete.Catalog(content()).unfiltered
      host.update(snapshot: snapshot, query: query, isEnabled: enabled, navigation: .menu)
      return snapshot
    }

    @Test("Disabled choices stay visible but are skipped by search and arrows")
    func disabledRows() {
      let host = Autocomplete.Host()
      var accepted = 0
      let snapshot = configure(host) {
        Autocomplete.Action("Disabled") { Issue.record("Disabled action ran") }.disabled()
        Autocomplete.Action("Enabled") { accepted += 1 }
      }
      #expect(snapshot.items.count == 2)
      #expect(snapshot.eligibleIDs.count == 1)
      #expect(host.highlight.highlighted == snapshot.items[1].id)
      #expect(host.handle(.accept))
      #expect(accepted == 1)
      #expect(!host.activate(snapshot.items[0].id))
    }

    @Test("Whole-control disabling protects primary, shortcut, and secondary actions")
    func disabledControl() {
      let host = Autocomplete.Host()
      let snapshot = configure(host, enabled: false) {
        Autocomplete.Action("Action") { Issue.record("Disabled primary action ran") }
          .secondaryActions([.init("Secondary", systemImage: "star") { Issue.record("Disabled secondary action ran") }])
      }
      #expect(host.highlight.highlighted == nil)
      #expect(!host.handle(.accept))
      #expect(!host.activate(snapshot.items[0].id))
      #expect(!host.activate(snapshot.items[0].id, secondary: 0))
      var dismissed = false
      host.dismiss = {
        dismissed = true; return true
      }
      #expect(host.handle(.dismiss))
      #expect(dismissed)
    }

    @Test("Secondary actions preserve selection and presentation")
    func secondaryAction() {
      let selection = SelectionStore("a")
      let favorites = SelectionStore<[String]>([])
      let host = Autocomplete.Host()
      host.dismissOnSelection = true
      var dismissals = 0
      host.dismiss = {
        dismissals += 1; return true
      }
      let snapshot = configure(host) {
        Autocomplete.Picker("Choice", selection: selection.binding) {
          Autocomplete.Choice("B", value: "b")
        }.favorites(favorites.binding)
      }
      #expect(host.activate(snapshot.items[0].id, secondary: 0))
      #expect(favorites.value == ["b"])
      #expect(selection.value == "a")
      #expect(dismissals == 0)
      #expect(host.activate(snapshot.items[0].id))
      #expect(selection.value == "b")
      #expect(dismissals == 1)
    }

    @Test("Replacing data and closures updates direct dispatch without changing identity")
    func currentAction() {
      let host = Autocomplete.Host()
      var value = 0
      let before = configure(host) { Autocomplete.Action("Item", id: 1) { value = 1 } }
      let after = configure(host) { Autocomplete.Action("Item", id: 1) { value = 2 } }
      #expect(before.items[0].id == after.items[0].id)
      #expect(host.handle(.accept))
      #expect(value == 2)
      _ = configure(host) {}
      #expect(!host.activate(before.items[0].id))
    }

    @Test("Keyboard targets include 10,000 rows without realizing any views")
    func offscreenNavigation() {
      let host = Autocomplete.Host()
      var accepted: Int?
      let snapshot = configure(host) {
        for index in 0..<10000 { Autocomplete.Action("Item \(index)", id: index) { accepted = index } }
      }
      #expect(snapshot.eligibleIDs.count == 10000)
      #expect(host.handle(.moveToLast))
      #expect(host.handle(.accept))
      #expect(accepted == 9999)
    }

    @Test("Unhandled commands propagate from engine and native text delegate")
    func commandDisposition() {
      let host = Autocomplete.Host()
      #expect(!host.handle(.accept))
      #expect(!host.handle(.moveDown))
      let coordinator = Autocomplete.InputField.Coordinator(text: .constant(""), onCommand: host.handle)
      let field = NSSearchField()
      let editor = NSTextView()
      #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
      _ = configure(host) { Autocomplete.Action("A") {} }
      #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
      #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.deleteToEndOfLine(_:))))
    }

    @Test("Return on a focused secondary action never activates the primary choice")
    func focusedSecondaryAction() {
      let selection = SelectionStore("Other")
      let favorites = SelectionStore<[String]>([])
      let host = Autocomplete.Host()
      let snapshot = configure(host) {
        Autocomplete.Picker("Projects", selection: selection.binding) {
          Autocomplete.Choice("Demo", value: "Demo")
        }.favorites(favorites.binding)
      }
      host.rowFocus = .secondary(snapshot.items[0].id, 0)
      #expect(host.handle(.accept))
      #expect(favorites.value == ["Demo"])
      #expect(selection.value == "Other")
    }

    @Test("Focused SwiftUI rows route shortcuts, Return, and Escape through the same engine")
    func focusedKeyRouting() {
      let selection = SelectionStore("Other")
      let favorites = SelectionStore<[String]>([])
      let host = Autocomplete.Host()
      let snapshot = configure(host) {
        Autocomplete.Picker("Projects", selection: selection.binding) {
          Autocomplete.Choice("Demo", value: "Demo")
        }.favorites(favorites.binding)
      }
      #expect(!host.handleFocusedKey("f", modifiers: [.command, .shift]))
      host.rowFocus = .secondary(snapshot.items[0].id, 0)
      #expect(host.handleFocusedKey("f", modifiers: [.command, .shift]))
      #expect(favorites.value == ["Demo"])
      #expect(host.handleFocusedKey(.return, modifiers: []))
      #expect(favorites.value.isEmpty)
      #expect(selection.value == "Other")
      var dismissed = false
      host.dismiss = {
        dismissed = true; return true
      }
      #expect(host.handleFocusedKey(.escape, modifiers: []))
      #expect(dismissed)
      #expect(!host.handleFocusedKey("x", modifiers: []))
    }

    private func event(
      _ key: String, code: UInt16, flags: NSEvent.ModifierFlags = .control, window: NSWindow? = nil
    ) -> NSEvent {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window?.windowNumber ?? 0, context: nil, characters: key,
        charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
    }

    @Test("Control-J/K and Control-N/P map to list navigation")
    func physicalKeys() {
      #expect(Autocomplete.Host.command(for: event("n", code: 45)) == .moveDown)
      #expect(Autocomplete.Host.command(for: event("p", code: 35)) == .moveUp)
      #expect(Autocomplete.Host.command(for: event("j", code: 38)) == .moveDown)
      #expect(Autocomplete.Host.command(for: event("k", code: 40)) == .moveUp)
    }

    @Test("Control-J/K navigate once from the search field or a focused row", arguments: [true, false])
    func vimNavigation(editing: Bool) {
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 260, height: 80),
        styleMask: [.borderless], backing: .buffered, defer: false)
      defer { window.contentView = nil }
      let host = Autocomplete.Host()
      defer { host.stop() }
      let snapshot = configure(host) {
        Autocomplete.Action("First") { Issue.record("Navigation accepted an item") }
        Autocomplete.Action("Disabled") { Issue.record("Navigation accepted an item") }.disabled()
        Autocomplete.Action("Second") { Issue.record("Navigation accepted an item") }
        Autocomplete.Action("Third") { Issue.record("Navigation accepted an item") }
      }
      let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
      window.contentView?.addSubview(field)
      host.inputField = field
      if editing {
        #expect(window.makeFirstResponder(field))
      } else {
        host.rowFocus = .item(snapshot.items[0].id)
      }
      let down = event("j", code: 38, window: window)
      let up = event("k", code: 40, window: window)
      #expect(host.handleEvent(down, window: window))
      #expect(host.highlight.highlighted == snapshot.items[2].id)
      #expect(host.handleEvent(up, window: window))
      #expect(host.highlight.highlighted == snapshot.items[0].id)
      for flags: NSEvent.ModifierFlags in [[], [.control, .shift], [.control, .command], [.control, .option]] {
        #expect(!host.handleEvent(event("j", code: 38, flags: flags, window: window), window: window))
      }
      #expect(host.highlight.highlighted == snapshot.items[0].id)
      if editing {
        #expect(host.handleKeyEquivalent(down))
        #expect(host.highlight.highlighted == snapshot.items[2].id)
        #expect(host.handleKeyEquivalent(up))
        #expect(host.highlight.highlighted == snapshot.items[0].id)
      }
      host.inputField = nil
      host.rowFocus = nil
      #expect(!host.handleEvent(down, window: window))
      #expect(!host.handleKeyEquivalent(down))
    }

    @Test("Focused SwiftUI rows support Control-J/K and Control-N/P")
    func focusedControlNavigation() {
      let host = Autocomplete.Host()
      let snapshot = configure(host) {
        Autocomplete.Action("First") { Issue.record("Navigation accepted an item") }
        Autocomplete.Action("Second") { Issue.record("Navigation accepted an item") }
        Autocomplete.Action("Third") { Issue.record("Navigation accepted an item") }
      }
      let bindings: [(KeyEquivalent, KeyEquivalent)] = [("j", "k"), ("n", "p")]
      for (down, up) in bindings {
        #expect(!host.handleFocusedKey(down, modifiers: .control))
        host.rowFocus = .item(snapshot.items[0].id)
        #expect(host.handleFocusedKey(down, modifiers: .control))
        #expect(host.highlight.highlighted == snapshot.items[1].id)
        #expect(host.handleFocusedKey(up, modifiers: .control))
        #expect(host.highlight.highlighted == snapshot.items[0].id)
        #expect(!host.handleFocusedKey(down, modifiers: [.control, .shift]))
        #expect(!host.handleFocusedKey(down, modifiers: []))
        host.rowFocus = nil
      }
    }

    @Test("Marked text keeps navigation, Return, and Escape in AppKit")
    func markedText() {
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 260, height: 80),
        styleMask: [.borderless], backing: .buffered, defer: false)
      defer { window.contentView = nil }
      let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
      window.contentView?.addSubview(field)
      window.makeFirstResponder(field)
      guard let editor = window.firstResponder as? NSTextView else { Issue.record("Missing field editor"); return }
      editor.setMarkedText(
        "ni", selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      let host = Autocomplete.Host()
      let snapshot = configure(host) {
        Autocomplete.Action("First") { Issue.record("Composition accepted an item") }
        Autocomplete.Action("Second") { Issue.record("Composition accepted an item") }
      }
      host.inputField = field
      let coordinator = Autocomplete.InputField.Coordinator(
        text: .constant("ni"),
        onCommand: { _ in
          Issue.record("Composition reached menu navigation"); return true
        })
      #expect(editor.hasMarkedText())
      #expect(!host.owns(event("\r", code: 36, flags: [], window: window), window: window))
      for (key, code): (String, UInt16) in [("j", 38), ("k", 40)] {
        let navigation = event(key, code: code, window: window)
        #expect(!host.handleEvent(navigation, window: window))
        #expect(!host.handleKeyEquivalent(navigation))
      }
      #expect(host.highlight.highlighted == snapshot.items[0].id)
      for selector in [
        #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)),
        #selector(NSResponder.cancelOperation(_:)),
      ] { #expect(!coordinator.control(field, textView: editor, doCommandBy: selector)) }
    }

    @Test("Local shortcuts require this control's focus and dispatch exactly once")
    func scopedShortcuts() {
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 260, height: 80),
        styleMask: [.borderless], backing: .buffered, defer: false)
      let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
      window.contentView?.addSubview(field)
      window.makeFirstResponder(field)
      defer { window.contentView = nil }
      let host = Autocomplete.Host()
      host.inputField = field
      var accepted = 0
      _ = configure(host) { Autocomplete.Action("Open") { accepted += 1 }.keyboardShortcut("o") }
      let shortcut = event("o", code: 31, flags: .command, window: window)
      #expect(host.handleEvent(shortcut, window: window))
      #expect(accepted == 1)
      #expect(!host.handleEvent(event("\r", code: 36, flags: [], window: window), window: window))
      host.inputField = nil
      #expect(!host.handleEvent(shortcut, window: window))
      #expect(accepted == 1)
    }
  }
#endif
