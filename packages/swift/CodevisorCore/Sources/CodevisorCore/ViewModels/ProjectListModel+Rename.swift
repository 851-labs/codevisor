import Foundation

extension ProjectListModel {
  @discardableResult
  public func renameSession(
    _ session: ChatSession, to title: String, errorReporter: ErrorReporter = .shared
  ) -> Task<Void, Never>? {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty,
      sessions.contains(where: { $0.serverId == session.serverId && $0.id == session.id })
    else { return nil }
    guard let client = clientForServer(session.serverId) else {
      errorReporter.report("Couldn't Rename Chat", message: "Connect to its machine and try again.")
      return nil
    }
    let key = ScopedSessionID(serverId: session.serverId, id: session.id)
    pendingSessionRenames[key] = title
    if let task = sessionRenameTasks[key] { return task }
    let task = Task {
      defer {
        sessionRenameTasks[key] = nil
        pendingSessionRenames[key] = nil
      }
      while let title = pendingSessionRenames.removeValue(forKey: key) {
        guard var current = sessions.first(where: { $0.serverId == key.serverId && $0.id == key.id }) else { return }
        current.title = title
        let lifetime = recordLifetimeGeneration(for: key.serverId)
        do {
          if pendingServerSessionIds.contains(key),
            let project = projects.first(where: { $0.serverId == key.serverId && $0.id == current.projectId })
          {
            _ = try await client.upsertProject(project)
          }
          _ = try await client.renameSession(current)
        } catch {
          errorReporter.report("Couldn't Rename Chat", error: error)
        }
        // Also recover a response lost after the server saved. Live events
        // can supersede this read through the usual synchronization guards.
        guard isCurrentRecordLifetime(lifetime, for: key.serverId) else { return }
        await refreshFromServer(serverId: key.serverId, client: client)
      }
    }
    sessionRenameTasks[key] = task
    return task
  }
}
