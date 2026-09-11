import Foundation

public enum BrowserLinkDestination: Equatable, Sendable {
  case backgroundTab
  case foregroundTab
  case window
  case split(SplitEdge)
}

extension Workspace {
  /// Insert beside the actual opener, even if another tab became active while
  /// the browser was handling the click. Selection/focus belongs to the caller.
  public mutating func insertBrowserPane(
    _ pane: PaneDescriptorState, from sourcePaneId: UUID, destination: BrowserLinkDestination
  ) -> (tabId: UUID, leafId: UUID)? {
    guard pane.kind == .browser,
      let index = centerTabs.firstIndex(where: { $0.root.groupId(containingPane: sourcePaneId) != nil }),
      let sourceLeaf = centerTabs[index].root.groupId(containingPane: sourcePaneId),
      !centerTabs.contains(where: { $0.root.groupId(containingPane: pane.id) != nil })
    else { return nil }
    let state = PaneGroupState(panes: [pane], selectedPaneId: pane.id)
    if case let .split(edge) = destination {
      let leafId = UUID()
      centerTabs[index].root = centerTabs[index].root.splitting(
        groupId: sourceLeaf, edge: edge, newGroupId: leafId, newGroupState: state)
      centerTabs[index].activeLeafId = leafId
      return (centerTabs[index].id, leafId)
    }
    let tab = WorkspaceTab(root: .leaf(state))
    centerTabs.insert(tab, at: index + 1)
    return (tab.id, tab.activeLeafId)
  }
}
