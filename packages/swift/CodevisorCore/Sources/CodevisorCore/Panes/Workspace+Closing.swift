import Foundation

extension Workspace {
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

  mutating func selectReplacementForClosedTab(_ closedTabId: UUID, previousTabs: [WorkspaceTab]) {
    guard !centerTabs.isEmpty, !centerTabs.contains(where: { $0.id == closedTabId }),
      let oldIndex = previousTabs.firstIndex(where: { $0.id == closedTabId })
    else { return }
    let tabs = centerTabs
    let index =
      previousTabs[(oldIndex + 1)...].lazy
      .compactMap { next in tabs.firstIndex(where: { $0.id == next.id }) }
      .first ?? tabs.count
    selectedCenterTabId = Self.replacementTab(afterRemovingAt: index, from: tabs).id
  }

  static func replacementTab(
    afterRemovingAt index: Int, from tabs: [WorkspaceTab]
  ) -> WorkspaceTab {
    index > 0 ? tabs[index - 1] : tabs[0]
  }
}
