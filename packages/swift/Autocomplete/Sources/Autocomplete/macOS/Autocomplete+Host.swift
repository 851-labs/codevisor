#if canImport(AppKit)
  import AppKit
  import Observation
  import SwiftUI

  extension Autocomplete {
    /// One interaction engine for popovers and inline suggestions. All input
    /// paths validate the same current snapshot and dispatch directly once.
    @MainActor
    @Observable
    final class Host {
      let highlight: Highlight<NodeID>
      @ObservationIgnored private(set) var snapshot = Snapshot()
      @ObservationIgnored var isEnabled = true
      @ObservationIgnored var rowFocus: FocusTarget?
      var hasRowFocus: Bool { rowFocus != nil }
      @ObservationIgnored var dismiss: () -> Bool = { false }
      @ObservationIgnored var dismissOnSelection = false
      @ObservationIgnored weak var inputField: NSSearchField?
      @ObservationIgnored weak var resultsView: NSView?
      @ObservationIgnored private var announcement: DispatchWorkItem?
      @ObservationIgnored private var previousQuery = ""

      init(navigation: Navigation = .menu) { highlight = Highlight(navigation: navigation) }

      func update(snapshot: Snapshot, query: String, isEnabled: Bool, navigation: Navigation) {
        self.snapshot = snapshot
        self.isEnabled = isEnabled
        highlight.navigation = navigation
        if isEnabled { highlight.reconcile(with: snapshot.eligibleIDs, query: query) } else { highlight.reset() }
        if query != previousQuery {
          previousQuery = query
          announce(includeCount: true)
        }
      }

      @discardableResult
      func activate(_ id: NodeID, secondary index: Int? = nil) -> Bool {
        guard isEnabled, let item = snapshot.byID[id], !item.definition.isDisabled else { return false }
        if let index {
          guard item.definition.secondaryActions.indices.contains(index) else { return false }
          item.definition.secondaryActions[index].perform()
        } else {
          if dismissOnSelection { _ = dismiss() }
          item.definition.perform()
        }
        return true
      }

      @discardableResult
      func handle(_ command: KeyCommand) -> Bool {
        if command == .dismiss { return dismiss() }
        guard isEnabled else { return false }
        if command == .accept {
          guard let target = highlight.highlighted else { return false }
          if case let .secondary(id, index) = rowFocus, id == target { return activate(target, secondary: index) }
          return activate(target)
        }
        guard !snapshot.eligibleIDs.isEmpty else { return false }
        return highlight.handle(command, targets: snapshot.eligibleIDs, accept: { _ = self.activate($0) }, dismiss: {})
      }

      func owns(_ event: NSEvent, window: NSWindow?) -> Bool {
        guard let window, event.window === window else { return false }
        if let editor = window.firstResponder as? NSTextView {
          return editor.delegate === inputField && !editor.hasMarkedText()
        }
        return hasRowFocus
      }

      func handleEvent(_ event: NSEvent, window: NSWindow?) -> Bool {
        guard owns(event, window: window) else { return false }
        return handleOwnedEvent(event, editing: window?.firstResponder is NSTextView)
      }

      /// AppKit can deliver a command directly to performKeyEquivalent rather
      /// than the event queue. The field itself provides the ownership scope.
      func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let field = inputField, let editor = field.window?.firstResponder as? NSTextView,
          editor.delegate === field, !editor.hasMarkedText()
        else { return false }
        return handleOwnedEvent(event, editing: true)
      }

      private func handleOwnedEvent(_ event: NSEvent, editing: Bool) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Text editing keeps unmodified character keys. AppKit's delegate,
        // after input-method processing, owns Return/arrows/Escape in a field.
        if !editing || !modifiers.isDisjoint(with: [.command, .control, .option]) {
          var flags: EventModifiers = []
          if modifiers.contains(.command) { flags.insert(.command) }
          if modifiers.contains(.control) { flags.insert(.control) }
          if modifiers.contains(.option) { flags.insert(.option) }
          if modifiers.contains(.shift) { flags.insert(.shift) }
          if handleShortcut(key: event.charactersIgnoringModifiers ?? "", modifiers: flags) { return true }
        }

        guard !editing, let command = Self.command(for: event) else { return false }
        return handle(command)
      }

      static func command(for event: NSEvent) -> KeyCommand? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .control {
          switch event.charactersIgnoringModifiers?.lowercased() {
          case "n": return .moveDown
          case "p": return .moveUp
          default: return nil
          }
        }
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 126: return .moveUp
        case 125: return .moveDown
        case 115: return .moveToFirst
        case 119: return .moveToLast
        case 36, 76: return .accept
        case 53: return .dismiss
        default: return nil
        }
      }

      /// Focused SwiftUI buttons also receive keys through their own responder
      /// path, which does not require AppKit's event-queue monitor.
      func handleFocusedKey(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        guard hasRowFocus else { return false }
        let modifiers = modifiers.intersection([.command, .control, .option, .shift])
        if handleShortcut(key: String(key.character), modifiers: modifiers) { return true }
        guard modifiers.isEmpty else { return false }
        let command: KeyCommand
        switch key {
        case .upArrow: command = .moveUp
        case .downArrow: command = .moveDown
        case .home: command = .moveToFirst
        case .end: command = .moveToLast
        case .return: command = .accept
        case .escape: command = .dismiss
        default: return false
        }
        return handle(command)
      }

      private func handleShortcut(key: String, modifiers: EventModifiers) -> Bool {
        func matches(_ shortcut: KeyboardShortcut?) -> Bool {
          guard let shortcut else { return false }
          return shortcut.modifiers == modifiers && String(shortcut.key.character).lowercased() == key.lowercased()
        }
        if let id = highlight.highlighted, let item = snapshot.byID[id] {
          for (index, action) in item.definition.secondaryActions.enumerated() where matches(action.shortcut) {
            return activate(id, secondary: index)
          }
        }
        if let item = snapshot.items.first(where: { !$0.definition.isDisabled && matches($0.definition.shortcut) }) {
          return activate(item.id)
        }
        return false
      }

      func linkResults(_ view: NSView) {
        resultsView = view
        inputField?.setAccessibilityLinkedUIElements([view])
      }

      func registerInput(_ field: NSSearchField) {
        inputField = field
        if let resultsView { field.setAccessibilityLinkedUIElements([resultsView]) }
      }

      func announce(includeCount: Bool = false) {
        announcement?.cancel()
        guard let field = inputField else { return }
        var parts: [String] = []
        if includeCount { parts.append(Strings.resultCount(snapshot.items.count)) }
        if let id = highlight.highlighted, let item = snapshot.byID[id],
          let index = snapshot.items.firstIndex(where: { $0.id == id })
        {
          parts.append(item.definition.title)
          parts.append(Strings.position(index + 1, count: snapshot.items.count))
          if item.definition.isSelected { parts.append(Strings.text("Selected")) }
          if item.definition.favoriteOrder != nil { parts.append(Strings.text("Favorite")) }
        }
        let text = parts.joined(separator: ", ")
        guard !text.isEmpty else { return }
        let work = DispatchWorkItem { [weak field] in
          guard let field else { return }
          NSAccessibility.post(
            element: field, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        announcement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
      }

      func stop() {
        announcement?.cancel()
        announcement = nil
        highlight.reset()
        snapshot = Snapshot()
        dismiss = { false }
        rowFocus = nil
      }
    }
  }
#endif
