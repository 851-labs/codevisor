import Foundation

extension WorkspaceSyncModel {
  @discardableResult
  public func reorderWorkspace(
    id: UUID, visibleIDs: [UUID], client: (any CodevisorServerClienting)? = nil
  ) -> Task<Void, Never>? {
    guard let workspace = repository.workspace(id: id),
      let position = WorkspaceSidebarOrder.position(for: id, in: visibleIDs, workspaces: repository.loadAll()),
      position != workspace.effectiveSidebarPosition
    else { return nil }
    guard workspace.isServerSynced else {
      if let store = navigationStore, var draft = store.layouts.draft(id: id),
        let layout = store.layouts.layout(for: id)
      {
        draft.sidebarPosition = position
        store.addDraft(draft, layout: layout)
      }
      return nil
    }
    let expectedRevision = max(1, workspace.sidebarOrderRevision)
    enqueue(
      .reorderWorkspace(workspaceId: id, position: position, expectedRevision: expectedRevision),
      serverId: workspace.serverId)
    return nil
  }
}
