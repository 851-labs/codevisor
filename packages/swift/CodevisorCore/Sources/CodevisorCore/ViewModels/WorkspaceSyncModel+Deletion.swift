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

    /// Workspace deletion is safe to apply immediately; the following
    /// coalesced snapshot refreshes session membership as well.
    public func removeWorkspace(id: UUID, serverId: String) {
        guard let workspace = repository.workspace(id: id),
            workspace.serverId == serverId
        else { return }
        sessionsInvalidatedByWorkspaceDeletion[serverId, default: []]
            .formUnion(workspace.chatSessionIds)
        repository.delete(id: id)
        revision &+= 1
    }
}
