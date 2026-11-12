import Foundation

extension Workspace {
  public mutating func foldTabsIntoSplits() {
    guard centerTabs.count > 1 else { return }

    let activeLeafId = selectedCenterTab?.activeLeafId
    let mainIndex = mainTabIndex
    var main = centerTabs[mainIndex]
    for (index, tab) in centerTabs.enumerated() where index != mainIndex && !tab.isPlaceholder {
      main.root = main.root.appendingTrailing(tab.root)
    }
    if let activeLeafId, main.root.group(id: activeLeafId) != nil { main.activeLeafId = activeLeafId }

    centerTabs = [main]
    selectedCenterTabId = main.id
  }

  private var mainTabIndex: Int {
    if let mainSessionId,
      let index = centerTabs.firstIndex(where: { $0.root.groupId(containingChat: mainSessionId) != nil })
    {
      return index
    }
    return centerTabs.firstIndex { !$0.isPlaceholder } ?? 0
  }
}

extension SplitNode {
  func appendingTrailing(_ node: SplitNode) -> SplitNode {
    guard case let .split(.horizontal, children) = self else {
      return .split(
        orientation: .horizontal,
        children: [SplitChild(fraction: 0.5, node: self), SplitChild(fraction: 0.5, node: node)])
    }
    let share = 1 / Double(children.count + 1)
    let shrunk = children.map { SplitChild(fraction: $0.fraction * (1 - share), node: $0.node) }
    return .split(orientation: .horizontal, children: shrunk + [SplitChild(fraction: share, node: node)])
  }
}
