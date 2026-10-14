import Foundation

extension WorkspaceSyncModel {
  @discardableResult
  public func reorderWorkspace(
    id: UUID, visibleIDs: [UUID], client: (any CodevisorServerClienting)? = nil
  ) -> Task<Void, Never>? {
    guard let workspace = repository.workspace(id: id), workspace.isServerSynced,
      let position = WorkspaceSidebarOrder.position(for: id, in: visibleIDs, workspaces: repository.loadAll()),
      position != workspace.effectiveSidebarPosition
    else { return nil }
    let expectedRevision = max(1, workspace.sidebarOrderRevision)
    enqueue(
      .reorderWorkspace(workspaceId: id, position: position, expectedRevision: expectedRevision),
      serverId: workspace.serverId)
    return nil
  }
}
