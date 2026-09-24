import Foundation

extension WorkspaceSyncModel {
  /// Shares a pane's content with the workspace's other devices. Where it
  /// sits -- tab, split, selection -- stays in this device's layout, which
  /// the caller has already saved.
  public func publishPane(
    _ pane: PaneDescriptorState,
    workspaceId: UUID,
    client: (any CodevisorServerClienting)? = nil
  ) {
    // The New Tab page is device-local: nothing to share.
    guard pane.kind != .newTab, let workspace = repository.workspace(id: workspaceId) else { return }
    enqueue(.upsertPane(pane, workspaceId: workspaceId), serverId: workspace.serverId)
  }

  /// The pane is already a chat in this device's layout when this is called.
  /// The server converts that exact pane id and attaches the chat in one
  /// step, so no device ever sees the pane twice.
  public func promotePaneToChat(
    _ pane: PaneDescriptorState,
    session: ChatSession,
    workspaceId: UUID,
    client: (any CodevisorServerClienting)? = nil
  ) {
    guard let workspace = repository.workspace(id: workspaceId) else { return }
    enqueue(.promotePane(pane, workspaceId: workspaceId, session: session), serverId: workspace.serverId)
  }

  /// Closes a pane on every device. The caller has already taken it out of
  /// this device's layout (closing a workspace's last pane leaves this
  /// device's New Tab page in its place, which is never shared).
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
