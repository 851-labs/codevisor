import Foundation

extension ProjectListModel {
  /// Drops every record stored under a server id — used when a machine
  /// identity turns out to be a duplicate (the local machine's own cloud
  /// twin), whose synced records would otherwise render as doubled
  /// projects and chats forever.
  public func removeAllRecords(serverId: String) {
    // Invalidate first, even when nothing has committed yet. The duplicate
    // identity is commonly discovered while its initial fetch is in flight.
    invalidateRecordLifetime(for: serverId)
    invalidateSnapshotRefreshes(for: serverId)
    let hadProjects = projects.contains { $0.serverId == serverId }
    let hadSessions = sessions.contains { $0.serverId == serverId }
    guard hadProjects || hadSessions else { return }
    projects.removeAll { $0.serverId == serverId }
    sessions.removeAll { $0.serverId == serverId }
    pendingServerProjectIds = pendingServerProjectIds.filter { $0.serverId != serverId }
    persistProjects()
    persistSessions()
  }

  /// Adds a project on an EXPLICIT machine — the fleet-wide picker's "New
  /// Project…" flow, which may target a machine other than the selected
  /// one. Dedupe and un-archive semantics match `addProject(folderURL:)`.
  ///
  /// The upsert is AWAITED so the returned record carries the server's git
  /// probe: the picker needs `isGitRepository` immediately to decide
  /// whether to offer the worktree step. A failed upsert still returns the
  /// local record (unprobed) — the add works offline, exactly as before.
  @discardableResult
  public func addProject(
    folderURL: URL,
    serverId: String,
    client: any CodevisorServerClienting
  ) async -> Project {
    let local: Project
    if let index = projects.firstIndex(where: {
      $0.serverId == serverId && $0.folderURL == folderURL
    }) {
      projects[index].isArchived = false
      local = projects[index]
    } else {
      local = Project.fromFolder(folderURL, serverId: serverId)
      projects.append(local)
    }
    persistProjects()
    pendingServerProjectIds.insert(
      ScopedSessionID(serverId: serverId, id: local.id)
    )
    do {
      let probed = try await client.upsertProject(local).project(serverId: serverId)
      if let index = projects.firstIndex(where: {
        $0.serverId == serverId && $0.id == local.id
      }) {
        projects[index].locations = probed.locations
        persistProjects()
        return projects[index]
      }
      return probed
    } catch {
      Log.sync.error(
        "Failed to sync project \(local.id.uuidString, privacy: .public) to the server: \(String(describing: error), privacy: .public)"
      )
      ErrorReporter.shared.report(
        .projectSyncFailed,
        title: "Couldn't Sync the Project to the Server",
        error: error
      )
      return local
    }
  }
}
