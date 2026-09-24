import Foundation

extension WorkspaceSyncModel {
  /// Renames a workspace everywhere. The name shows immediately and reaches
  /// the workspace's machine through the outbox, including after being
  /// offline. A draft is renamed on this device until the server has it.
  @discardableResult
  public func renameWorkspace(
    _ renamed: Workspace,
    client: (any CodevisorServerClienting)? = nil,
    errorReporter: ErrorReporter = .shared
  ) -> Task<Void, Never>? {
    let name = renamed.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let current = repository.workspace(id: renamed.id), current.serverId == renamed.serverId,
      !name.isEmpty
    else { return nil }
    if current.isServerSynced {
      enqueue(
        .renameWorkspace(workspaceId: renamed.id, name: name, hasCustomName: renamed.hasCustomName),
        serverId: renamed.serverId)
    } else if let store = navigationStore, var draft = store.layouts.draft(id: renamed.id),
      let layout = store.layouts.layout(for: renamed.id)
    {
      draft.name = name
      store.addDraft(draft, layout: layout)
    }
    return nil
  }
}
