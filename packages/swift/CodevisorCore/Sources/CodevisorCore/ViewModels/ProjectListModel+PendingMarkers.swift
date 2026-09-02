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

  func persistPendingArchivedSessions() {
    guard let legacyMigrationStore else { return }
    let snapshot = Array(pendingArchivedSessionIds)
    let storageKey = Self.pendingArchivedSessionsKey
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
          "Failed to persist pending archived session markers: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  func loadPendingArchivedSessions() {
    guard let legacyMigrationStore,
      let data = legacyMigrationStore.loadData(forKey: Self.pendingArchivedSessionsKey),
      let ids = try? JSONDecoder().decode([ScopedSessionID].self, from: data)
    else { return }
    pendingArchivedSessionIds = Set(ids)
  }
}
