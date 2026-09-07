import CodevisorCore
import Foundation

extension SidebarView {
  /// Active fleet sessions provide workspace ownership and routing. Their
  /// order never controls the workspace list.
  var activeSessionItems: [SidebarSessionListItem] {
    let projects = list.projects.filter {
      !$0.isArchived && environment.machines.machine(for: $0.serverId) != nil
    }
    let projectsByID = Dictionary(
      projects.map { ($0.sidebarFleetItemID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    return list.sessions.compactMap { session in
      guard !session.isArchived,
        session.origin == .codevisor || list.showsImportedSessions,
        let project = projectsByID[.project(serverId: session.serverId, id: session.projectId)]
      else { return nil }
      return SidebarSessionListItem(session: session, project: project)
    }
  }

  /// Saved workspace ranks own the list order. Workspaces without a saved
  /// rank enter newest-first, including empty workspaces.
  var workspaceItems: [SidebarWorkspaceListItem] {
    // Repository writes are not observable; local and remote layout writes
    // invalidate these tokens so the sidebar re-reads the tabs.
    _ = workspaceRevision
    _ = environment.workspaceSync.revision
    _ = store?.workspaceLayoutRevision
    let sessionsByID = Dictionary(
      activeSessionItems.map { ($0.id, $0.session) },
      uniquingKeysWith: { first, _ in first }
    )
    let workspaces = environment.workspaces.loadAll()
      .filter { !$0.isArchived && environment.machines.machine(for: $0.serverId) != nil }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }
    let items = workspaces.compactMap { workspace -> SidebarWorkspaceListItem? in
      let routedSessionIDs = workspace.chatSessionIds.filter {
        environment.workspaces.workspaceId(forSession: $0) == workspace.id
      }
      // Suppress superseded automatic workspaces whose chats all moved to
      // another workspace. Empty workspaces have no chat IDs and remain visible.
      guard workspace.chatSessionIds.isEmpty || !routedSessionIDs.isEmpty else { return nil }
      // A terminal-only workspace can still route through an archived chat
      // retained in the session index after its chat tab was closed.
      let routingSession =
        routedSessionIDs.lazy.compactMap {
          sessionsByID[.session(serverId: workspace.serverId, id: $0)]
        }.first
        ?? list.sessions.first {
          $0.serverId == workspace.serverId
            && environment.workspaces.workspaceId(forSession: $0.id) == workspace.id
        }
      return SidebarWorkspaceListItem(workspace: workspace, routingSession: routingSession)
    }
    return manuallyOrderedWorkspaces(items)
  }
}
