import Foundation

extension Workspace {
  /// Removes empty leaves after pane lifecycle hooks have persisted a close.
  /// Selection changes only when its tab or active leaf has disappeared.
  public mutating func pruneClosedCenterTab(_ tabId: UUID) {
    guard let index = centerTabs.firstIndex(where: { $0.id == tabId }) else { return }
    let oldLeaves = centerTabs[index].root.allGroups.map(\.id)
    let oldActiveLeaf = centerTabs[index].activeLeafId
    if let root = centerTabs[index].root.prunedEmptyGroups {
      centerTabs[index].root = root
      if root.group(id: oldActiveLeaf) == nil {
        let survivors = root.allGroups.map(\.id)
        let oldIndex = oldLeaves.firstIndex(of: oldActiveLeaf) ?? 0
        centerTabs[index].activeLeafId = survivors[min(oldIndex, survivors.count - 1)]
      }
    } else {
      centerTabs.remove(at: index)
    }
    if centerTabs.isEmpty {
      let replacement = WorkspaceTab.placeholder()
      centerTabs = [replacement]
      selectedCenterTabId = replacement.id
    } else if !centerTabs.contains(where: { $0.id == selectedCenterTabId }) {
      selectedCenterTabId = Self.replacementTab(afterRemovingAt: index, from: centerTabs).id
    }
  }

  /// The tab that takes over when the selected tab at `index` closes: the
  /// nearest tab the sidebar lists — the one above first, then below — so
  /// closing never lands on a tab holding only hidden agent terminals.
  /// When no listed tab remains, the plain right-neighbor rule applies.
  static func replacementTab(
    afterRemovingAt index: Int, from tabs: [WorkspaceTab],
    visibility: PaneNavigationVisibility = PaneNavigationVisibility()
  ) -> WorkspaceTab {
    func isListed(_ tab: WorkspaceTab) -> Bool {
      tab.root.allGroups.contains { group in
        guard let pane = group.state.selectedPane ?? group.state.panes.first else { return true }
        return visibility.includes(pane)
      }
    }
    let before = tabs[..<index].last(where: isListed)
    let after = tabs[index...].first(where: isListed)
    return before ?? after ?? tabs[min(index, tabs.count - 1)]
  }
}
