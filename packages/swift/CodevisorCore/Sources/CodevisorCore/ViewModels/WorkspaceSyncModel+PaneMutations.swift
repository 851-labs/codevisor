import Foundation

extension WorkspaceSyncModel {
  public func publishPane(
    _ pane: PaneDescriptorState,
    workspaceId: UUID,
    client: (any CodevisorServerClienting)? = nil
  ) {
    guard !pane.kind.isDeviceLocal, let workspace = repository.workspace(id: workspaceId) else { return }
    enqueue(.upsertPane(pane, workspaceId: workspaceId), serverId: workspace.serverId)
  }

  public func promotePaneToChat(
    _ pane: PaneDescriptorState,
    session: ChatSession,
    workspaceId: UUID,
    client: (any CodevisorServerClienting)? = nil
  ) {
    guard let workspace = repository.workspace(id: workspaceId) else { return }
    enqueue(.promotePane(pane, workspaceId: workspaceId, session: session), serverId: workspace.serverId)
  }

  public func deletePane(
    id: UUID,
    workspaceId: UUID,
    optimisticReplacement: PaneDescriptorState? = nil,
    client: (any CodevisorServerClienting)? = nil
  ) {
    guard let workspace = repository.workspace(id: workspaceId), workspace.isServerSynced else { return }
    enqueue(.closePane(paneId: id, workspaceId: workspaceId), serverId: workspace.serverId)
  }
}
