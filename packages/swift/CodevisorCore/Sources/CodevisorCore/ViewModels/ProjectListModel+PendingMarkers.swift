import Foundation

extension ProjectListModel {
  private static let pendingServerSessionsKey = "pending-server-sessions-v1"
  private static let pendingServerProjectsKey = "pending-server-projects-v1"
  private static let pendingArchivedSessionsKey = "pending-archived-sessions-v1"

  func persistPendingServerProjects() {
    guard let legacyMigrationStore else { return }
    let snapshot = Array(pendingServerProjectIds)
    let storageKey = Self.pendingServerProjectsKey
    PersistenceEncoding.enqueueLatest(
      owner: markerPersistenceOwner,
      key: storageKey,
      delay: 0.05
    ) {
      do {
        let data = try PersistenceEncoding.encoder.encode(snapshot)
        try legacyMigrationStore.saveData(data, forKey: storageKey)
      } catch {
        Log.sync.error(
          "Failed to persist pending project markers: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  func loadPendingServerProjects() {
    guard let legacyMigrationStore,
      let data = legacyMigrationStore.loadData(forKey: Self.pendingServerProjectsKey),
      let ids = try? JSONDecoder().decode([ScopedSessionID].self, from: data)
    else { return }
    pendingServerProjectIds = Set(ids)
  }

  func persistPendingServerSessions() {
    guard let legacyMigrationStore else { return }
    let snapshot = Array(pendingServerSessionIds)
    let storageKey = Self.pendingServerSessionsKey
    PersistenceEncoding.enqueueLatest(
      owner: markerPersistenceOwner,
      key: storageKey,
      delay: 0.05
    ) {
      do {
        let data = try PersistenceEncoding.encoder.encode(snapshot)
        try legacyMigrationStore.saveData(data, forKey: storageKey)
      } catch {
        Log.sync.error(
          "Failed to persist pending session markers: \(String(describing: error), privacy: .public)")
      }
    }
  }

  func loadPendingServerSessions() {
    guard let legacyMigrationStore,
      let data = legacyMigrationStore.loadData(forKey: Self.pendingServerSessionsKey),
      let ids = try? JSONDecoder().decode([ScopedSessionID].self, from: data)
    else { return }
    pendingServerSessionIds = Set(ids)
  }

  /// Deletes the archived-chat override this client used to keep.
  ///
  /// That marker forced `isArchived = true` onto a chat on every refresh and
  /// was only ever retired when the server AGREED the chat was archived. An
  /// archive upload that failed -- or another client restoring the chat first
  /// -- left it set forever, so one machine hid a chat every other machine
  /// showed, with nothing in the app able to repair it. It is the main reason
  /// users reported clients disagreeing about archived chats.
  ///
  /// Chats no longer carry archive state at all, so the override has nothing
  /// left to force. Dropping the key lets the next navigation snapshot be
  /// authoritative, which is exactly what unsticks the affected installs.
  func purgeLegacyArchivedSessionMarkers() {
    guard let legacyMigrationStore,
      legacyMigrationStore.loadData(forKey: Self.pendingArchivedSessionsKey) != nil
    else { return }
    do {
      try legacyMigrationStore.removeData(forKey: Self.pendingArchivedSessionsKey)
    } catch {
      Log.sync.error(
        "Failed to drop legacy archived session markers: \(String(describing: error), privacy: .public)"
      )
    }
  }
}
