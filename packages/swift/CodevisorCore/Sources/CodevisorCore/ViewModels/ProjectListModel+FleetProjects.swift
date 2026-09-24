import Foundation

extension ProjectListModel {
  /// Forgets every record from a machine identity -- used when one turns out
  /// to be a duplicate (the local machine's own cloud twin), whose records
  /// would otherwise render as doubled projects and chats.
  public func removeAllRecords(serverId: String) {
    navigationStore?.forget(machineId: serverId)
  }

  /// Adds a project on an explicit machine -- the fleet-wide picker's "New
  /// Project…" flow. The project shows at once; the upsert is also awaited
  /// here because the picker needs the server's git probe
  /// (`isGitRepository`) to decide whether to offer the worktree step. If the
  /// machine can't be reached the local record comes back unprobed and the
  /// outbox keeps trying.
  @discardableResult
  public func addProject(
    folderURL: URL,
    serverId: String,
    client: any CodevisorServerClienting
  ) async -> Project {
    let local = addProject(folderURL: folderURL, serverId: serverId)
    do {
      let probed = try await client.upsertProject(local).project(serverId: serverId)
      var merged = local
      merged.locations = probed.locations
      // The remote is observed server-side; adopting it now lets the new
      // record join its cross-machine group immediately.
      merged.repoUrl = probed.repoUrl
      merged.repoKey = probed.repoKey
      return merged
    } catch {
      Log.sync.error(
        "Couldn't probe project \(local.id.uuidString, privacy: .public) yet: \(String(describing: error), privacy: .public)"
      )
      return local
    }
  }
}
