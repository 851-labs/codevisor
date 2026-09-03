import AppKit
import CodevisorCore

extension ShortcutID {
  /// The "split this pane" command for an edge. Leading and top have no key
  /// equivalent; they are here so menus can still source their titles.
  static func split(towards edge: SplitEdge) -> ShortcutID {
    switch edge {
    case .leading: .splitLeft
    case .trailing: .splitRight
    case .top: .splitUp
    case .bottom: .splitDown
    }
  }

  /// The "move focus to the adjacent split" command for an edge.
  static func focusSplit(towards edge: SplitEdge) -> ShortcutID {
    switch edge {
    case .leading: .focusSplitLeft
    case .trailing: .focusSplitRight
    case .top: .focusSplitAbove
    case .bottom: .focusSplitBelow
    }
  }
}

extension ShortcutCatalog {
  /// The workspace shortcuts AppKit has to match by hand, paired with the
  /// command they run.
  ///
  /// Note ⌘W: the Tabs & Splits menu binds it to "Close Split", but with a
  /// pane focused it closes the whole tab. That asymmetry predates this table
  /// and is preserved deliberately — changing it is a product decision, not a
  /// refactor.
  private static let paneCommandBindings: [(ShortcutID, PaneGroupCommand)] = [
    (.focusSplitLeft, .focusSplit(.leading)),
    (.focusSplitRight, .focusSplit(.trailing)),
    (.focusSplitAbove, .focusSplit(.top)),
    (.focusSplitBelow, .focusSplit(.bottom)),
    (.previousTab, .previousTab),
    (.nextTab, .nextTab),
    (.splitDown, .split(.bottom)),
    (.previousSplit, .previousSplit),
    (.nextSplit, .nextSplit),
    (.newTab, .newTab),
    (.reopenClosedPane, .reopenClosedPane),
    (.splitRight, .split(.trailing)),
    (.closeSplit, .closeTab),
    (.toggleBottomPanel, .togglePanel),
  ]

  /// The workspace command `event` triggers, if any.
  ///
  /// Both AppKit key-equivalent paths route through this — the terminal
  /// surface's `performKeyEquivalent` and the focus controller's local event
  /// monitor — so they cannot drift from each other or from the menu.
  ///
  /// - Parameter includingPanelToggle: ⌘J is only claimed here while a
  ///   terminal surface is first responder, because the SwiftUI focused-scene
  ///   value that backs the menu command is not reliably published then.
  ///   Everywhere else the menu handles it and this must not intercept.
  static func paneCommand(
    for event: NSEvent,
    includingPanelToggle: Bool = false
  ) -> PaneGroupCommand? {
    for (id, command) in paneCommandBindings {
      if id == .toggleBottomPanel, !includingPanelToggle { continue }
      if let combo = combo(for: id), combo.matches(event) { return command }
    }
    return selectTabCommand(for: event)
  }

  /// ⌘1–⌘9 select the first nine tabs. A range rather than a single combo, so
  /// it is matched separately from the table above.
  private static func selectTabCommand(for event: NSEvent) -> PaneGroupCommand? {
    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.function, .numericPad])
    guard modifierFlags == .command,
      let characters = event.charactersIgnoringModifiers?.lowercased(),
      characters.count == 1,
      let digit = Int(characters),
      (1...9).contains(digit)
    else { return nil }
    return .selectTab(digit - 1)
  }
}
