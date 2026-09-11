import Foundation

extension WorkspaceSyncModel {
  /// Metadata events already carry the authoritative workspace. Applying them
  /// directly keeps archive/restore and rename independent of another network
  /// request. New identities and older marker-only events still need a snapshot
  /// to establish session membership and panes.
  func applyServerWorkspaceEvent(_ event: ServerEventEnvelope, serverId: String) -> Bool {
    guard event.kind == "workspace.updated",
      let data = try? JSONEncoder().encode(event.payload),
      let record = try? JSONDecoder().decode(ServerWorkspace.self, from: data),
      let id = UUID(uuidString: record.id),
      id == UUID(uuidString: event.subjectId),
      let existing = repository.workspace(id: id),
      existing.serverId == serverId,
      existing.projectId == UUID(uuidString: record.projectId),
      existing.isServerSynced
    else { return false }

    // An older snapshot may already be in flight. It must not restore the
    // metadata that this event just replaced, even if this event is a no-op.
    refreshGenerationByServer[serverId, default: 0] &+= 1
    var workspace = existing
    Self.applyMetadata(record, to: &workspace)
    if workspace != existing {
      repository.save(workspace)
      revision &+= 1
    }
    return true
  }

  static func applyMetadata(_ record: ServerWorkspace, to workspace: inout Workspace) {
    // Preserve native custom names predating workspace sync until the server
    // carries an explicit name. Match snapshot reconciliation exactly.
    if !workspace.hasCustomName || record.hasCustomName {
      workspace.name = record.name
      workspace.hasCustomName = record.hasCustomName
    }
    workspace.rootDirectory = record.rootDirectory ?? workspace.rootDirectory
    workspace.isArchived = record.isArchived
    workspace.isServerSynced = true
  }
}
