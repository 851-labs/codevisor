import AppKit
import CodevisorCore

extension ShortcutID {
  static func split(towards edge: SplitEdge) -> ShortcutID {
    switch edge {
    case .leading: .splitLeft
    case .trailing: .splitRight
    case .top: .splitUp
    case .bottom: .splitDown
    }
  }

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
  private static let paneCommandBindings: [(ShortcutID, PaneGroupCommand)] = [
    (.previousTab, .previousTab),
    (.nextTab, .nextTab),
    (.previousTabInWorkspace, .previousTabInWorkspace),
    (.nextTabInWorkspace, .nextTabInWorkspace),
    (.previousWorkspace, .previousWorkspace),
    (.nextWorkspace, .nextWorkspace),
    (.focusSplitLeft, .focusSplit(.leading)),
    (.focusSplitRight, .focusSplit(.trailing)),
    (.focusSplitAbove, .focusSplit(.top)),
    (.focusSplitBelow, .focusSplit(.bottom)),
    (.splitDown, .split(.bottom)),
    (.previousSplit, .previousSplit),
    (.nextSplit, .nextSplit),
    (.newTab, .newTab),
    (.reopenClosedPane, .reopenClosedPane),
    (.splitRight, .split(.trailing)),
    (.closeSplit, .closeTab),
  ]

  static func paneCommand(for event: NSEvent) -> PaneGroupCommand? {
    for (id, command) in paneCommandBindings {
      let definition = definition(for: id)
      let combos = definition.combo.map { [$0] + definition.alternateCombos } ?? []
      if combos.contains(where: { $0.matches(event) }) { return command }
    }
    return selectTabCommand(for: event)
  }

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
