import SwiftUI
import CodevisorCore

extension SidebarView {
  /// Where the workspace lives. Nil when its machine is unknown — an
  /// unresolved server isn't necessarily this one, so it stays unlabeled.
  func machineName(forServer serverId: String) -> String? {
    let machine = environment.machines.machine(for: serverId)
    return machine.map { $0.isLocal ? "This Mac" : $0.name }
  }

  /// Whether the sidebar's selection is showing this workspace: its selected
  /// chat lives here, or the workspace itself is selected (it has no chat).
  func routesSelectedSession(_ workspace: Workspace) -> Bool {
    switch selection {
    case let .session(serverId, sessionId):
      guard serverId == workspace.serverId else { return false }
      return environment.workspaces.workspaceId(forSession: sessionId) == workspace.id
    case let .workspace(serverId, id):
      return serverId == workspace.serverId && id == workspace.id
    case .newChat, .none:
      return false
    }
  }

  /// Archives the WORKSPACE (not just a chat): the record is flagged, its
  /// live chats archive with it, and the row leaves the list. Layout is
  /// kept — restoring any of its chats revives the whole workspace.
  func archiveWorkspace(_ workspace: Workspace) {
    // Whether the selection lives in this workspace, decided BEFORE the
    // archive (a scratch workspace's discard also drops its session
    // index, which this lookup depends on).
    let selectionLeaves: Bool
    if case let .session(serverId, sessionId) = selection,
      serverId == workspace.serverId,
      environment.workspaces.workspaceId(forSession: sessionId) == workspace.id
    {
      selectionLeaves = true
    } else {
      selectionLeaves = false
    }
    environment.archiveWorkspace(workspace)
    if selectionLeaves {
      // Land on the most recent remaining chat; only an empty machine
      // falls through to creating a fresh scratch workspace.
      selectNextChat(serverId: workspace.serverId)
    }
  }

}
