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

  /// Archives a workspace. Its chats go with it by belonging to it, and the
  /// server reclaims the worktree the workspace owns.
  public func archiveWorkspace(_ workspace: Workspace) {
    setWorkspaceArchived(workspace, true)
  }

  /// Restores a workspace, which brings back its tabs and its worktree.
  public func unarchiveWorkspace(_ workspace: Workspace) {
    setWorkspaceArchived(workspace, false)
  }

  /// Writes the archived flag locally, then confirms it with the server.
  ///
  /// The local write is optimistic so the sidebar responds immediately, but
  /// it is NOT authoritative: a failed upload reverts it. Keeping a local-only
  /// archive was how one machine came to hide a workspace every other machine
  /// still showed, with no marker, no retry and nothing able to notice.
  /// Losing the optimism on failure is the honest outcome — the user sees the
  /// workspace come back rather than silently diverging from their fleet.
  private func setWorkspaceArchived(_ workspace: Workspace, _ isArchived: Bool) {
    guard machines.machine(for: workspace.serverId) != nil else {
      Log.sync.error(
        "Cannot archive a workspace on an unknown machine: \(workspace.serverId, privacy: .public)"
      )
      return
    }
    var updated = workspace
    updated.isArchived = isArchived
    workspaces.save(updated)
    workspaceSync.noteLocalMutation()

    let client = machines.client(for: workspace.serverId)
    Task { [weak self] in
      do {
        try await client.setWorkspaceArchived(id: workspace.id, isArchived: isArchived)
      } catch {
        Log.sync.error(
          "Failed to sync workspace archive state: \(String(describing: error), privacy: .public)"
        )
        guard let self, let current = self.workspaces.workspace(id: workspace.id),
          current.isArchived == isArchived
        else { return }
        var reverted = current
        reverted.isArchived = !isArchived
        self.workspaces.save(reverted)
        self.workspaceSync.noteLocalMutation()
      }
    }
  }
}
