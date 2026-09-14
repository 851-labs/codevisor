import Foundation

extension WorkspaceSyncModel {
  /// Rename the current record, preserving layout changes made while the alert was open.
  @discardableResult
  public func renameWorkspace(
    _ renamed: Workspace,
    client: (any CodevisorServerClienting)?
  ) -> Task<Void, Never>? {
    guard var workspace = repository.workspace(id: renamed.id),
      workspace.name != renamed.name || workspace.hasCustomName != renamed.hasCustomName
    else { return nil }
    workspace.name = renamed.name
    workspace.hasCustomName = renamed.hasCustomName
    repository.save(workspace)
    refreshGenerationByServer[workspace.serverId, default: 0] &+= 1
    noteLocalMutation()
    guard let client else { return nil }
    return Task {
      do {
        try await client.renameWorkspace(
          id: renamed.id, name: renamed.name, hasCustomName: renamed.hasCustomName
        )
      } catch {
        Log.sync.error("Failed to sync workspace rename: \(String(describing: error), privacy: .public)")
      }
    }
  }
}
