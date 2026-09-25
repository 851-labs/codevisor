import Foundation

extension WorkspaceSyncModel {
  /// Moves a workspace in the sidebar. The new position shows immediately
  /// and the latest move wins on the server, so it stays put and reaches
  /// every device. Call once per completed move, not per drag step.
  @discardableResult
  public func reorderWorkspace(
    id: UUID, visibleIDs: [UUID], client: (any CodevisorServerClienting)? = nil
  ) -> Task<Void, Never>? {
    guard let workspace = repository.workspace(id: id), workspace.isServerSynced,
      let position = WorkspaceSidebarOrder.position(for: id, in: visibleIDs, workspaces: repository.loadAll()),
      position != workspace.effectiveSidebarPosition
    else { return nil }
    // Only servers from before last-write-wins ordering read this. Every
    // server row starts at order revision 1.
    let expectedRevision = max(1, workspace.sidebarOrderRevision)
    enqueue(
      .reorderWorkspace(workspaceId: id, position: position, expectedRevision: expectedRevision),
      serverId: workspace.serverId)
    return nil
  }
}
