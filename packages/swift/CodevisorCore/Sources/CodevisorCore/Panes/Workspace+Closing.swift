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

  /// Re-selects after a rebuild dropped the selected tab — a close applied
  /// through sync prunes the tab before `pruneClosedCenterTab` can see it —
  /// with the same neighbor that rule picks. `previousTabs` is the order
  /// before the rebuild, which locates where the closed tab sat.
  mutating func selectReplacementForClosedTab(_ closedTabId: UUID, previousTabs: [WorkspaceTab]) {
    guard !centerTabs.isEmpty, !centerTabs.contains(where: { $0.id == closedTabId }),
      let oldIndex = previousTabs.firstIndex(where: { $0.id == closedTabId })
    else { return }
    // The closed tab's slot: just before the first survivor that followed it.
    let tabs = centerTabs
    let index =
      previousTabs[(oldIndex + 1)...].lazy
      .compactMap { next in tabs.firstIndex(where: { $0.id == next.id }) }
      .first ?? tabs.count
    selectedCenterTabId = Self.replacementTab(afterRemovingAt: index, from: tabs).id
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
