import Foundation

extension WorkspaceSyncModel {
  func applyNavigationDelta(
    _ delta: ServerNavigationDelta, previous: ServerNavigationSnapshot,
    snapshot: ServerNavigationSnapshot, serverId: String
  ) {
    refreshGenerationByServer[serverId, default: 0] &+= 1
    let deletedPanes = Set(delta.deleted.filter { $0.table == "workspace_panes" }.map { $0.id.lowercased() })
    let changedPanes = Set(delta.panes.map { $0.id.lowercased() }).union(deletedPanes)
    let paneWorkspaces = Set(
      (delta.panes + previous.panes.filter { changedPanes.contains($0.id.lowercased()) })
        .compactMap { UUID(uuidString: $0.workspaceId) })
    let affected = Set(delta.workspaces.compactMap { UUID(uuidString: $0.id) })
      .union(delta.deleted.filter { $0.table == "workspaces" }.compactMap { UUID(uuidString: $0.id) })
      .union(paneWorkspaces)
    reconcile(
      snapshot.workspaces, paneRecords: snapshot.panes, protectedLocalPaneIds: [],
      assignments: projectList.workspaceAssignments(for: serverId), serverId: serverId,
      affectedWorkspaceIds: affected, paneWorkspaceIds: paneWorkspaces)
  }
}
