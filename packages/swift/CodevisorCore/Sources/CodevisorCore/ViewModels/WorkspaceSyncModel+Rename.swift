import Foundation

extension WorkspaceSyncModel {
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
