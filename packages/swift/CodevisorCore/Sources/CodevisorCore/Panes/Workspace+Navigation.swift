import Foundation

public enum WorkspaceDestination: Hashable, Sendable {
  case tab(UUID)
  case leaf(UUID)
  case chat(UUID)
  case pane(UUID)
}

public enum WorkspaceSelectionRoute: Hashable, Sendable {
  case session(serverId: String, id: UUID)
  case workspace(serverId: String, id: UUID)
}

extension Workspace {
  public func selectionRoute(
    activatedChatSessionId: UUID?,
    routingSessionId: UUID?,
    selectionAlreadyRoutesWorkspace: Bool
  ) -> WorkspaceSelectionRoute? {
    if let activatedChatSessionId {
      return .session(serverId: serverId, id: activatedChatSessionId)
    }
    if selectionAlreadyRoutesWorkspace { return nil }
    if let routingSessionId {
      return .session(serverId: serverId, id: routingSessionId)
    }
    return .workspace(serverId: serverId, id: id)
  }

  @discardableResult
  public mutating func selectDestination(_ destination: WorkspaceDestination) -> Bool {
    let tabIndex: Int
    let leafId: UUID
    switch destination {
    case let .tab(id):
      guard let index = centerTabs.firstIndex(where: { $0.id == id }),
        let active = centerTabs[index].resolvedActiveLeafId(preferred: nil)
      else { return false }
      tabIndex = index
      leafId = active
    case let .leaf(id):
      guard let index = centerTabs.firstIndex(where: { $0.root.group(id: id) != nil }) else {
        return false
      }
      tabIndex = index
      leafId = id
    case let .chat(id):
      guard let index = centerTabs.firstIndex(where: { $0.root.groupId(containingChat: id) != nil }),
        let leaf = centerTabs[index].root.groupId(containingChat: id)
      else { return false }
      tabIndex = index
      leafId = leaf
      centerTabs[index].root = centerTabs[index].root.updatingGroup(id: leaf) { state in
        var state = state
        if let pane = state.panes.first(where: { $0.kind == .chat && $0.chatSessionId == id }) {
          state.selectPane(id: pane.id)
        }
        return state
      }
    case let .pane(id):
      guard
        let index = centerTabs.firstIndex(where: { tab in
          tab.root.allGroups.contains { $0.state.panes.contains { $0.id == id } }
        }),
        let leaf = centerTabs[index].root.allGroups.first(where: {
          $0.state.panes.contains { $0.id == id }
        })
      else { return false }
      tabIndex = index
      leafId = leaf.id
      centerTabs[index].root = centerTabs[index].root.updatingGroup(id: leaf.id) { state in
        var state = state
        state.selectPane(id: id)
        return state
      }
    }
    centerTabs[tabIndex].activeLeafId = leafId
    selectedCenterTabId = centerTabs[tabIndex].id
    return true
  }
}
