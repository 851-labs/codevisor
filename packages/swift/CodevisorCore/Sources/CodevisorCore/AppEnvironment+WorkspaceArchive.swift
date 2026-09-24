import Foundation

extension AppEnvironment {
  /// Closes a chat: its pane goes away and the chat stops being a tab.
  ///
  /// Closing is not archiving. The chat keeps its transcript and its
  /// workspace membership, and `workspace_panes` — server-owned, and part of
  /// every client's navigation snapshot including a fresh install's — is the
  /// single record of whether it is open. An emptied workspace stays live and
  /// shows its New Tab page.
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

  /// Archives a workspace. Its chats go with it by belonging to it, and the
  /// server reclaims the worktree the workspace owns.
  public func archiveWorkspace(_ workspace: Workspace) {
    setWorkspaceArchived(workspace, true)
  }

  /// Restores a workspace, which brings back its tabs and its worktree.
  public func unarchiveWorkspace(_ workspace: Workspace) {
    setWorkspaceArchived(workspace, false)
  }

  /// Asks the workspace's machine to change its archived flag. The sidebar
  /// reflects it at once and keeps doing so while the request waits -- across
  /// relaunches and while offline -- and if the server refuses it, the
  /// server's state is what shows. No device ever keeps an archive state of
  /// its own, which is what used to let one device hide a workspace every
  /// other device still showed.
  private func setWorkspaceArchived(_ workspace: Workspace, _ isArchived: Bool) {
    guard workspace.isServerSynced else {
      // A draft the server never had: archiving it just discards it.
      if isArchived { workspaces.delete(id: workspace.id) }
      return
    }
    navigationStore.enqueue(
      .setWorkspaceArchived(workspaceId: workspace.id, isArchived: isArchived), machineId: workspace.serverId)
  }
}
