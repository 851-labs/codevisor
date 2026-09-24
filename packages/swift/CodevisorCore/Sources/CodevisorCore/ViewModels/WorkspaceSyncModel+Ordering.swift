import Foundation

extension WorkspaceSyncModel {
  /// Moves a workspace in the sidebar. The new position shows immediately;
  /// the server applies it only if nobody else reordered since this device
  /// last saw the order, and otherwise this device shows the server's order.
  @discardableResult
  public func reorderWorkspace(
    id: UUID, visibleIDs: [UUID], client: (any CodevisorServerClienting)? = nil
  ) -> Task<Void, Never>? {
    guard let workspace = repository.workspace(id: id), workspace.isServerSynced,
      let position = WorkspaceSidebarOrder.position(for: id, in: visibleIDs, workspaces: repository.loadAll()),
      position != workspace.effectiveSidebarPosition
    else { return nil }
    // Every server row starts at order revision 1.
    let expectedRevision = max(1, workspace.sidebarOrderRevision)
    enqueue(
      .reorderWorkspace(workspaceId: id, position: position, expectedRevision: expectedRevision),
      serverId: workspace.serverId)
    return nil
  }
}
