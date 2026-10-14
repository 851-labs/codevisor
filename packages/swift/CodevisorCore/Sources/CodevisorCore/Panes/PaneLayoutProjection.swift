import Foundation

public enum PaneLayoutProjection {
  public static func flatten(_ workspace: Workspace) -> PaneGroupState {
    let candidates = workspace.centerTabs.flatMap { tab in
      tab.root.allGroups.flatMap(\.state.panes)
    }
    var seen = Set<UUID>()
    let panes = candidates.filter { seen.insert($0.id).inserted }
    let selected = workspace.selectedCenterTab.flatMap { tab in
      tab.root.group(id: tab.activeLeafId)?.selectedPaneId
    }
    return PaneGroupState(
      panes: panes,
      selectedPaneId: panes.contains(where: { $0.id == selected }) ? selected : panes.first?.id
    )
  }

  public static func apply(_ state: PaneGroupState, to workspace: inout Workspace) {
    let byId = Dictionary(state.panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let treeIds = Set(workspace.centerTabs.flatMap { $0.root.allGroups.flatMap { $0.state.panes.map(\.id) } })
    var placed = Set<UUID>()
    var tabs: [WorkspaceTab] = []
    for tab in workspace.centerTabs {
      var root = tab.root
      for group in tab.root.allGroups {
        root = root.updatingGroup(id: group.id) { old in
          var updated = old
          updated.panes = old.panes.compactMap { pane in
            if let replacement = byId[pane.id] {
              return placed.insert(pane.id).inserted ? replacement : nil
            }
            if let replacement = state.panes.first(where: {
              !treeIds.contains($0.id) && !placed.contains($0.id) && sameResource($0, pane)
            }) {
              placed.insert(replacement.id)
              if updated.selectedPaneId == pane.id { updated.selectedPaneId = replacement.id }
              return replacement
            }
            return nil
          }
          if let selected = updated.selectedPaneId,
            !updated.panes.contains(where: { $0.id == selected })
          {
            updated.selectedPaneId = updated.panes.first?.id
          }
          return updated
        }
      }
      guard let pruned = root.prunedEmptyGroups else { continue }
      tabs.append(
        WorkspaceTab(id: tab.id, customTitle: tab.customTitle, root: pruned, activeLeafId: tab.activeLeafId)
      )
    }
    for pane in state.panes where !placed.contains(pane.id) {
      placed.insert(pane.id)
      tabs.append(WorkspaceTab(root: .leaf(PaneGroupState(panes: [pane], selectedPaneId: pane.id))))
    }
    if tabs.isEmpty {
      tabs = [WorkspaceTab.placeholder()]
    }

    if let selected = state.selectedPaneId,
      let index = tabs.firstIndex(where: { $0.root.groupId(containingPane: selected) != nil }),
      let leafId = tabs[index].root.groupId(containingPane: selected)
    {
      tabs[index].activeLeafId = leafId
      tabs[index].root = tabs[index].root.updatingGroup(id: leafId) { group in
        var updated = group
        updated.selectPane(id: selected)
        return updated
      }
      workspace.selectedCenterTabId = tabs[index].id
    } else if !tabs.contains(where: { $0.id == workspace.selectedCenterTabId }) {
      workspace.selectedCenterTabId = tabs[0].id
    }
    workspace.centerTabs = tabs
  }

  public static func sameResource(_ lhs: PaneDescriptorState, _ rhs: PaneDescriptorState) -> Bool {
    guard lhs.kind == rhs.kind else { return false }
    switch lhs.kind {
    case .chat:
      return lhs.chatSessionId != nil && lhs.chatSessionId == rhs.chatSessionId
    case .terminal:
      return lhs.terminalKey.caseInsensitiveCompare(rhs.terminalKey) == .orderedSame
    case .subagent:
      return lhs.ownerChatSessionId == rhs.ownerChatSessionId
        && lhs.subagentToolCallId != nil && lhs.subagentToolCallId == rhs.subagentToolCallId
    case .newTab, .plugin, .document, .browser, .screenSharing, .review, .simulator:
      return false
    }
  }
}
