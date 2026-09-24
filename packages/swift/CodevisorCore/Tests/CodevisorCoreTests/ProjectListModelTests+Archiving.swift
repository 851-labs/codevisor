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
    let persistence = InMemoryStore()
    try persistence.saveData(
      Data(#"[{"serverId":"local","id":"\#(UUID().uuidString)"}]"#.utf8),
      forKey: "pending-archived-sessions-v1"
    )

    // Opening the app's navigation storage runs the one-time migration.
    let environment = AppEnvironment(
      navigationPersistence: persistence,
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: AppSettingsModel(store: InMemoryStore())
    )

    #expect(persistence.loadData(forKey: "pending-archived-sessions-v1") == nil)
    #expect(environment.navigationStore.pendingIntents.isEmpty)
  }

  /// Dropping a duplicate machine identity must take everything it owned
  /// with it -- including changes still waiting to be sent -- or they would
  /// re-apply to live rows if the identity came back.
  @Test("Dropping a machine's records drops its waiting changes too")
  func removingMachineRecordsDropsWaitingChanges() async throws {
    let fixture = NavigationFixture()
    let model = fixture.projectList
    let twin = Project.fromFolder(URL(fileURLWithPath: "/srv/twin"), serverId: "cloud:twin")
    await fixture.install(machineId: "cloud:twin", projects: [twin])
    let project = model.addProject(folderURL: URL(fileURLWithPath: "/srv/other"), serverId: "cloud:twin")
    model.newSession(in: project, syncToServer: false)
    model.removeProject(twin)
    let local = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/kept"))

    model.removeAllRecords(serverId: "cloud:twin")

    #expect(fixture.store.pendingIntents.map(\.machineId) == ["local"])
    #expect(!fixture.store.hasCache(for: "cloud:twin"))
    #expect(model.projects.map(\.id) == [local.id])
    #expect(model.sessions.isEmpty)
  }
}
