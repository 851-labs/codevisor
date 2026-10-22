import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("MachineController data upgrades")
struct MachineControllerDataUpgradeTests {
  @Test("A migrating machine is followed at the update cadence and recovers once ready")
  func passiveMigrationFollowsThenRecovers() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureMigration(
      reports: [
        ServerMigrationProgress(id: "chat", name: "Updating chat history", completed: 40, total: 100)
      ],
      immediately: true
    )
    let clock = TestClock()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      clientFactory: { _ in fake },
      preparationSleep: clock.sleep
    )
    defer { controller.stopEventSync() }
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0"))
    let remote = accountMachine("remote-box")
    signIn(controller, machines: [remote])

    await controller.prepareMachine(remote.id)

    let connection = try #require(controller.connectionsById[remote.id])
    #expect(connection.dataUpgradeProgress?.name == "Updating chat history")
    #expect(connection.status?.label == "Updating server data…")
    #expect(connection.status?.isReachable == false)
    #expect(controller.availability(for: remote.id) == .failed("Updating server data…"))
    let row = try #require(center.components.first { $0.kind == .server })
    #expect(row.phase == .updating)
    #expect(row.detailText == "Updating chat history 40%")
    #expect(row.machineId == remote.id)

    await clock.waitForSleep(.seconds(2))
    #expect(connection.preparation.failures == 0)

    clock.advance(by: .seconds(2))
    try await waitUntil { connection.status?.isReachable == true }
    #expect(controller.availability(for: remote.id) == .ready)
    #expect(connection.dataUpgradeProgress == nil)
    try await waitUntil { connection.updateInfo != nil }
    #expect(center.components.first { $0.kind == .server }?.phase == .idle)
  }

  @Test("A failed data upgrade shows as a failed row with the server's reason")
  func passiveMigrationFailure() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureMigration(reports: [], failure: "disk full", immediately: true)
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      clientFactory: { _ in fake }
    )
    defer { controller.stopEventSync() }
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0"))
    let remote = accountMachine("remote-box")
    signIn(controller, machines: [remote])

    await controller.refreshStatus(for: remote.id)

    #expect(controller.statusByMachineId[remote.id]?.label == "Server data update failed")
    let row = try #require(center.components.first { $0.kind == .server })
    #expect(row.phase == .failed("disk full"))
    #expect(row.detailText == "Update failed: disk full")
    #expect(row.updateAvailable == false)
  }
}
