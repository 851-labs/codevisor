import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
extension ProjectListModelTests {
  /// Clients used to keep a durable "this chat is archived" override that was
  /// only ever retired once the server agreed. A failed upload -- or another
  /// client restoring the chat first -- left it set forever, so one machine
  /// hid a chat every other machine showed. Chats no longer carry archive
  /// state at all, so the override is dropped on the first launch that sees it.
  @Test("Legacy archived-chat overrides are dropped so the server wins again")
  func purgesLegacyArchivedSessionMarkers() async throws {
    let migrationStore = InMemoryStore()
    let scoped = [ProjectListModel.ScopedSessionID(serverId: "local", id: UUID())]
    try migrationStore.saveData(
      PersistenceEncoding.encoder.encode(scoped),
      forKey: "pending-archived-sessions-v1"
    )

    _ = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      legacyMigrationStore: migrationStore
    )

    #expect(migrationStore.loadData(forKey: "pending-archived-sessions-v1") == nil)
  }

  /// Pruning a duplicate machine identity used to purge only the project
  /// markers, stranding the rest under a server id that could come back and
  /// re-apply them to live rows.
  @Test("Dropping a machine's records purges every marker it owned")
  func removingMachineRecordsPurgesAllMarkers() async throws {
    let store = InMemoryStore()
    let model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: store),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      legacyMigrationStore: InMemoryStore()
    )
    let sessionId = UUID()
    let projectId = UUID()
    model.pendingServerProjectIds.insert(ProjectListModel.ScopedSessionID(serverId: "cloud:twin", id: projectId))
    model.pendingServerSessionIds.insert(ProjectListModel.ScopedSessionID(serverId: "cloud:twin", id: sessionId))
    model.pendingDeletedProjectIds.insert(ProjectListModel.ScopedSessionID(serverId: "cloud:twin", id: projectId))

    // No rows exist under that id: the purge must still run, because the
    // duplicate is usually found while its first fetch is still in flight.
    model.removeAllRecords(serverId: "cloud:twin")

    #expect(model.pendingServerProjectIds.isEmpty)
    #expect(model.pendingServerSessionIds.isEmpty)
    #expect(model.pendingDeletedProjectIds.isEmpty)
  }
}
