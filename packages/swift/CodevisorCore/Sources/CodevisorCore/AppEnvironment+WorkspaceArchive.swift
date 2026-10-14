import Foundation

extension AppEnvironment {
  public func closeSession(_ session: ChatSession) {
    removeActivePanes(for: session)
  }

  private func removeActivePanes(for session: ChatSession, in knownWorkspace: Workspace? = nil) {
    let workspace =
      knownWorkspace
      ?? workspaces.workspaceId(forSession: session.id)
      .flatMap { workspaces.workspace(id: $0) }
    guard let workspace, !workspace.isArchived else { return }
    let paneIds =
      (workspace.centerTabs.flatMap { tab in
        tab.root.allGroups.flatMap(\.state.panes)
      })
      .filter { $0.kind == .chat && $0.chatSessionId == session.id }
      .map(\.id)
    for paneId in paneIds {
      workspaceSync.closePaneLocally(id: paneId, workspaceId: workspace.id, repository: workspaces)
    }
  }

  public func archiveWorkspace(_ workspace: Workspace) {
    setWorkspaceArchived(workspace, true)
  }

  public func unarchiveWorkspace(_ workspace: Workspace) {
    setWorkspaceArchived(workspace, false)
  }

  private func setWorkspaceArchived(_ workspace: Workspace, _ isArchived: Bool) {
    guard workspace.isServerSynced else {
      if isArchived { workspaces.delete(id: workspace.id) }
      return
    }
    navigationStore.enqueue(
      .setWorkspaceArchived(workspaceId: workspace.id, isArchived: isArchived), machineId: workspace.serverId)
  }
}
