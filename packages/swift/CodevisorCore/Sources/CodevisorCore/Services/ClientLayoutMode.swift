import Foundation

public enum ClientLayoutMode: Sendable, Equatable {
  case tabs
  case tabsAndSplits
  case splits
  case conversation

  public init(compact: Bool) {
    self = compact ? .tabs : .tabsAndSplits
  }

  public var actions: [String] {
    switch self {
    case .tabs: ["new_tab", "reorder_tabs"]
    case .tabsAndSplits: ["new_tab", "reorder_tabs", "split", "move", "detach", "resize"]
    case .splits: ["split", "move", "resize"]
    case .conversation: []
    }
  }

  func rejection(of kind: String) -> ClientControlError {
    switch self {
    case .splits: ClientControlError(Self.splitsOnlyMessage(for: kind))
    case .conversation:
      ClientControlError(
        "This client shows a bot conversation on its own, with no panes beside it; arrange it from a Mac client.")
    case .tabs, .tabsAndSplits: ClientControlError("Layout action is unsupported on this client")
    }
  }

  private static func splitsOnlyMessage(for kind: String) -> String {
    switch kind {
    case "new_tab": "Bot conversations show splits only; use split instead of new_tab."
    case "detach": "Bot conversations show splits only; use move to rearrange the pane instead of detach."
    case "reorder_tabs": "Bot conversations show splits only, so there are no tabs to reorder."
    default: "Layout action is unsupported in a bot conversation; use split, move, or resize."
    }
  }
}
