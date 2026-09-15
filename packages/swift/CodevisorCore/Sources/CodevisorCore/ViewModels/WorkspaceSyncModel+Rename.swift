import Foundation

extension WorkspaceSyncModel {
  /// A failed write must not leave a local name that differs from the server.
  @discardableResult
  public func renameWorkspace(
    _ renamed: Workspace,
    client: (any CodevisorServerClienting)?,
    errorReporter: ErrorReporter = .shared
  ) -> Task<Void, Never>? {
    guard repository.workspace(id: renamed.id)?.serverId == renamed.serverId,
      !renamed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    guard let client else {
      errorReporter.report("Couldn't Rename Workspace", message: "Connect to its machine and try again.")
      return nil
    }
    var normalized = renamed
    normalized.name = renamed.name.trimmingCharacters(in: .whitespacesAndNewlines)
    pendingWorkspaceRenames[renamed.id] = normalized
    if let task = workspaceRenameTasks[renamed.id] { return task }
    let task = Task {
      defer {
        workspaceRenameTasks[renamed.id] = nil
        pendingWorkspaceRenames[renamed.id] = nil
      }
      // Serialize writes to one workspace and coalesce intermediate names.
      var resolvedId = renamed.id
      while let intent = pendingWorkspaceRenames.removeValue(forKey: renamed.id) {
        guard let current = repository.workspace(id: resolvedId) ?? repository.workspace(id: intent.id),
          current.serverId == intent.serverId
        else { return }
        let lifetime = projectList.recordLifetimeGeneration(for: intent.serverId)
        do {
          // Resolve or publish a legacy native workspace's server identity.
          guard let targetId = try await publishWorkspaceIfNeeded(current, client: client) else {
            throw CodevisorServerClientError.invalidResponse
          }
          resolvedId = targetId
          try await client.renameWorkspace(id: targetId, name: intent.name, hasCustomName: intent.hasCustomName)
        } catch {
          errorReporter.report("Couldn't Rename Workspace", error: error)
        }
        // Read the current server state, including after an ambiguous network
        // failure. Existing generation guards reject stale snapshots.
        guard projectList.isCurrentRecordLifetime(lifetime, for: intent.serverId) else { return }
        await refreshFromServer(serverId: intent.serverId, client: client)
      }
    }
    workspaceRenameTasks[renamed.id] = task
    return task
  }
}
