import Foundation

/// A local navigation intent. Resolving it only changes layout selection;
/// session connections and pane content belong to the destination's view.
public enum WorkspaceDestination: Hashable, Sendable {
  case tab(UUID)
  case leaf(UUID)
  case chat(UUID)
  case pane(UUID)
}

/// Where the app's sidebar selection should land after a workspace destination
/// is activated. `selectDestination` has already moved layout selection; this
/// decides only what the detail area shows.
public enum WorkspaceSelectionRoute: Hashable, Sendable {
  /// A real chat session of this workspace.
  case session(serverId: String, id: UUID)
  /// The workspace itself. A workspace owns its server identity, project and
  /// layout independently of any chat, so one that has never hosted a chat is
  /// still a place the user can be.
  case workspace(serverId: String, id: UUID)
}

extension Workspace {
  /// Resolves what the selection should become when a tab or leaf of this
  /// workspace is activated. Returns nil to leave the current selection alone.
  ///
  /// - Parameters:
  ///   - activatedChatSessionId: the chat owned by the activated destination,
  ///     or nil when it hosts none (a New Tab, terminal or screen-sharing pane).
  ///   - routingSessionId: a session already routed to this workspace, used as
  ///     today's fallback when the activated destination has no chat of its own.
  ///   - selectionAlreadyRoutesWorkspace: the current selection is a chat that
  ///     lives in this workspace, so the detail area already shows it.
  public func selectionRoute(
    activatedChatSessionId: UUID?,
    routingSessionId: UUID?,
    selectionAlreadyRoutesWorkspace: Bool
  ) -> WorkspaceSelectionRoute? {
    // An actual chat always wins: unchanged behaviour for every workspace
    // that has one.
    if let activatedChatSessionId {
      return .session(serverId: serverId, id: activatedChatSessionId)
    }
    if selectionAlreadyRoutesWorkspace { return nil }
    if let routingSessionId {
      return .session(serverId: serverId, id: routingSessionId)
    }
    // No chat anywhere in this workspace: address the workspace itself rather
    // than leaving the selection pointing at some other destination.
    return .workspace(serverId: serverId, id: id)
  }
}

extension Workspace {
  /// Select all levels together so the first destination render, toolbar,
  /// and sidebar agree before any pane begins loading. Invalid intents leave
  /// the current selection intact.
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
