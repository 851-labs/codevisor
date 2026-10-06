import Foundation

extension PaneDescriptorState {
  /// Agent terminals attach to an existing process; user terminals create a shell.
  public var isAgentTerminal: Bool { kind == .terminal && attachOnly }
}

/// Presentation policy shared by native navigation surfaces. Keeping this out
/// of persistence lets a future preference reveal the same running terminals.
public struct PaneNavigationVisibility: Sendable {
  public var hideAgentTerminals: Bool

  public init(hideAgentTerminals: Bool = true) {
    self.hideAgentTerminals = hideAgentTerminals
  }

  public func includes(_ pane: PaneDescriptorState) -> Bool {
    !hideAgentTerminals || !pane.isAgentTerminal
  }

  /// Whether navigation lists a tab: at least one of its splits shows a
  /// listed pane (an empty split counts, so a fresh tab is never hidden).
  public func includes(_ tab: WorkspaceTab) -> Bool {
    tab.root.allGroups.contains { group in
      guard let pane = group.state.selectedPane ?? group.state.panes.first else { return true }
      return includes(pane)
    }
  }
}

extension Workspace {
  /// The top tabs navigation lists, in order: what the tab strip shows and
  /// what ⌘1–⌘9 and ⇧⌘[ / ⇧⌘] step through.
  public func listedCenterTabs(
    visibility: PaneNavigationVisibility = PaneNavigationVisibility()
  ) -> [WorkspaceTab] {
    centerTabs.filter(visibility.includes)
  }
}
