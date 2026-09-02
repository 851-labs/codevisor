import Foundation

extension AppEnvironment {
  /// Archives a chat without changing its workspace. This is the tab-close
  /// behavior: an empty workspace remains available for its New Tab page.
  /// The pane usually disappeared before this call; removing any remaining
  /// references also makes this safe for navigation surfaces.
  public func archiveSession(_ session: ChatSession) {
    removeActivePanes(for: session)
    projectList.archiveSession(session)
  }

  /// Archives a chat and, when it was the workspace's final active chat,
  /// archives the workspace with it. This is the sidebar archive policy.
  /// Returns true when the workspace was archived so callers can leave its
  /// now-hidden route.
  @discardableResult
  public func archiveSessionAndWorkspaceIfEmpty(_ session: ChatSession) -> Bool {
    guard let workspaceId = workspaces.workspaceId(forSession: session.id),
      let workspace = workspaces.workspace(id: workspaceId),
      !workspace.isArchived
    else {
      projectList.archiveSession(session)
      return false
    }

    let hasOtherActiveChat = projectList.sessions.contains { candidate in
      candidate.serverId == workspace.serverId
        && candidate.id != session.id
        && !candidate.isArchived
        && workspaces.workspaceId(forSession: candidate.id) == workspace.id
    }
    if hasOtherActiveChat {
      removeActivePanes(for: session, in: workspace)
    }
    projectList.archiveSession(session)
    guard !hasOtherActiveChat else { return false }

    setWorkspaceArchived(workspace, true)
    return true
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
      } + workspace.bottomGroup.panes)
      .filter { $0.kind == .chat && $0.chatSessionId == session.id }
      .map(\.id)
    let client = machines.machine(for: workspace.serverId).map { _ in
      machines.client(for: workspace.serverId) as any CodevisorServerClienting
    }
    for paneId in paneIds {
      workspaceSync.closePaneLocally(
        id: paneId,
        workspaceId: workspace.id,
        repository: workspaces,
        client: client
      )
    }
  }

  /// Archives a workspace and every active chat that belongs to it while
  /// retaining its pane layout for a later restore.
  public func archiveWorkspace(_ workspace: Workspace) {
    setWorkspaceArchived(workspace, true)

    for session in projectList.sessions
    where
      session.serverId == workspace.serverId
      && !session.isArchived
      && workspaces.workspaceId(forSession: session.id) == workspace.id
    {
      projectList.archiveSession(session)
    }
  }

  /// Restores a workspace. Its chats are revived by the server's cascade
  /// (it archived them, so it owns un-archiving them); locally we clear the
  /// flag so the row reappears immediately rather than after a refresh.
  public func unarchiveWorkspace(_ workspace: Workspace) {
    setWorkspaceArchived(workspace, false)
  }

  /// Writes the archived flag locally AND mirrors it to the server.
  ///
  /// The local write is what the sidebar reads, so it stays first and
  /// unconditional — the archive must work offline. The upload is
  /// best-effort and fire-and-forget: without it the flag never left this
  /// machine, so other devices kept showing the workspace and the server
  /// never cascaded the archive to its chats.
  private func setWorkspaceArchived(_ workspace: Workspace, _ isArchived: Bool) {
    var updated = workspace
    updated.isArchived = isArchived
    workspaces.save(updated)
    workspaceSync.noteLocalMutation()

    guard machines.machine(for: workspace.serverId) != nil else { return }
    let client = machines.client(for: workspace.serverId)
    Task {
      do {
        try await client.setWorkspaceArchived(id: workspace.id, isArchived: isArchived)
      } catch {
        Log.sync.error(
          "Failed to sync workspace archive state: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }
}
