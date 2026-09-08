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
      let replacement = WorkspaceTab(root: .leaf(PaneGroupState()))
      centerTabs = [replacement]
      selectedCenterTabId = replacement.id
    } else if !centerTabs.contains(where: { $0.id == selectedCenterTabId }) {
      selectedCenterTabId = centerTabs[min(index, centerTabs.count - 1)].id
    }
  }
}
