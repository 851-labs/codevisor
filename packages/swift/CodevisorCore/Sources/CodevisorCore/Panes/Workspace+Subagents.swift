import Foundation

extension Workspace {
  @discardableResult
  public mutating func pruneOrphanedSubagentPanes() -> [PaneDescriptorState] {
    let chats = Set(chatSessionIds)
    let orphans = allPanes.filter { pane in
      pane.kind == .subagent && !(pane.ownerChatSessionId.map(chats.contains) ?? false)
    }
    guard !orphans.isEmpty else { return [] }
    for orphan in orphans {
      WorkspaceSyncModel.removePane(id: orphan.id, from: &self)
    }
    WorkspaceSyncModel.pruneEmptyCenterTabs(in: &self)
    WorkspaceSyncModel.ensureUsableLayout(&self)
    return orphans
  }

  public mutating func replacePane(
    id: UUID, with pane: PaneDescriptorState
  ) -> (tabId: UUID, leafId: UUID)? {
    guard !centerTabs.contains(where: { $0.root.groupId(containingPane: pane.id) != nil }),
      let index = centerTabs.firstIndex(where: { $0.root.groupId(containingPane: id) != nil }),
      let leafId = centerTabs[index].root.groupId(containingPane: id)
    else { return nil }
    centerTabs[index].root = centerTabs[index].root.updatingGroup(id: leafId) { state in
      var state = state
      guard let position = state.panes.firstIndex(where: { $0.id == id }) else { return state }
      state.panes[position] = pane
      state.selectedPaneId = pane.id
      return state
    }
    centerTabs[index].activeLeafId = leafId
    return (centerTabs[index].id, leafId)
  }
}
