import Foundation

// Deletion lives outside the class body and primary file for the size ratchet.
extension WorkspaceSyncModel {
  /// Drops every workspace stored under a server id — the counterpart of
  /// `ProjectListModel.removeAllRecords` for duplicate machine identities.
  public func removeWorkspaces(serverId: String) {
    // Prevent an already-running snapshot from restoring the identity
    // after this prune, including when no workspace had committed yet.
    refreshGenerationByServer[serverId, default: 0] &+= 1
    for workspace in repository.loadAll() where workspace.serverId == serverId {
      repository.delete(id: workspace.id)
    }
    revision &+= 1
  }

  /// Drop the identity immediately and invalidate routes through its cached
  /// chats, even while their session records await reconciliation.
  public func removeWorkspace(id: UUID, serverId: String) {
    // Invalidate even when the row has not been hydrated yet.
    refreshGenerationByServer[serverId, default: 0] &+= 1
    guard let workspace = repository.workspace(id: id),
      workspace.serverId == serverId
    else { return }
    sessionsInvalidatedByWorkspaceDeletion[serverId, default: []]
      .formUnion(workspace.chatSessionIds)
    repository.delete(id: id)
    revision &+= 1
  }

  /// Project deletion cascades in the database without individual workspace
  /// events. Remove empty workspaces too; macOS can list them without a chat.
  func removeWorkspaces(projectId: UUID, serverId: String) {
    refreshGenerationByServer[serverId, default: 0] &+= 1
    for workspace in repository.loadAll()
    where workspace.serverId == serverId && workspace.projectId == projectId {
      removeWorkspace(id: workspace.id, serverId: serverId)
    }
  }

  /// A deleted chat cannot remain as an orphan pane while a follow-up
  /// snapshot retries, including legacy layouts without server assignments.
  func removeSessionPanes(id: UUID, serverId: String) {
    refreshGenerationByServer[serverId, default: 0] &+= 1
    for workspace in repository.loadAll() where workspace.serverId == serverId {
      for pane in Self.allPanes(in: workspace) where pane.kind == .chat && pane.chatSessionId == id {
        closePaneLocally(id: pane.id, workspaceId: workspace.id, repository: repository)
      }
    }
  }
}
