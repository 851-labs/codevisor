import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
extension ProjectListModelTests {
  @Test("Legacy archived-chat overrides are dropped so the server wins again")
  func purgesLegacyArchivedSessionMarkers() async throws {
    let persistence = InMemoryStore()
    try persistence.saveData(
      Data(#"[{"serverId":"local","id":"\#(UUID().uuidString)"}]"#.utf8),
      forKey: "pending-archived-sessions-v1"
    )

    let environment = AppEnvironment(
      navigationPersistence: persistence,
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: AppSettingsModel(store: InMemoryStore())
    )

    #expect(persistence.loadData(forKey: "pending-archived-sessions-v1") == nil)
    #expect(environment.navigationStore.pendingIntents.isEmpty)
  }

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
