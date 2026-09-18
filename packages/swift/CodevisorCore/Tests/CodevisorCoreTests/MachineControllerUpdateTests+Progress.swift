import Foundation
import Testing
@testable import CodevisorCore

extension MachineControllerUpdateTests {
  @Test("Remote progress advances the row and deadline; stalled progress times out", arguments: [false, true])
  func remoteProgress(stalls: Bool) async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "1.0", latest: "2.0")
    fake.applyProgressReports = [
      ServerUpdateApplyState(state: "installing", message: "Downloading…", progress: 0.42, at: "attempt-1"),
      ServerUpdateApplyState(state: "installing", message: "Preparing…", progress: 0.75, at: "attempt-2"),
      ServerUpdateApplyState(state: "installing", message: "Installing…", at: "attempt-3"),
    ]
    if stalls {
      fake.applyProgressReports = (0..<10).map {
        ServerUpdateApplyState(state: "installing", at: "attempt-\($0)")
      }
    }
    let remote = CodevisorMachine(
      id: "remote-a", name: "Remote", baseURL: URL(string: "http://remote.test")!, kind: "remote")
    let store = InMemoryStore()
    try store.saveData(
      JSONEncoder().encode(MachineRegistry(selectedMachineId: "local", remoteMachines: [remote])), forKey: "machines")
    let clock = AdvancingServerUpdateScheduler()
    let controller = MachineController(
      store: store,
      projectList: ProjectListModel(
        projectRepository: DefaultProjectRepository(store: InMemoryStore()),
        sessionRepository: DefaultSessionRepository(store: InMemoryStore())
      ),
      clientFactory: { _ in fake },
      updatePollAttempts: 4,
      updateScheduler: clock.scheduler
    )
    defer { controller.stopEventSync() }
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0"))
    await controller.refreshStatus(for: remote.id)
    var rows: [UpdateComponent] = []
    clock.onSleep = {
      if let row = center.components.first(where: { $0.kind == .server }) { rows.append(row) }
    }

    await controller.updateServer(machineId: remote.id)

    if stalls {
      #expect(clock.requestedIntervals.count == 5)
      #expect(controller.serverUpdatePhase(for: remote.id) != .idle)
      #expect(controller.serverUpdatePhase(for: remote.id) != .updating)
      #expect(controller.connectionsById[remote.id]?.updateProgress == nil)
      return
    }
    #expect(rows.contains { $0.progress == 0.42 && $0.detailText == "Downloading… 42%" })
    #expect(rows.contains { $0.progress == 0.75 && $0.statusMessage == "Preparing…" })
    #expect(rows.contains { $0.progress == nil && $0.statusMessage == "Installing…" })
    #expect(rows.contains { $0.progress == nil && $0.statusMessage == "Restarting…" })
    #expect(controller.connectionsById[remote.id]?.updateProgress == nil)
    #expect(controller.serverUpdatePhase(for: remote.id) == .idle)
  }
}

extension MachineControllerUpdateTests {
  private struct MigrationFixture {
    let controller: MachineController
    let center: UpdateCenter
    let clock: AdvancingServerUpdateScheduler
    let remote: CodevisorMachine
  }

  private func makeMigrationFixture(
    fake: SyncFakeServerClient,
    pollAttempts: Int
  ) throws -> MigrationFixture {
    let remote = CodevisorMachine(
      id: "remote-a", name: "Remote", baseURL: URL(string: "http://remote.test")!, kind: "remote")
    let store = InMemoryStore()
    try store.saveData(
      JSONEncoder().encode(MachineRegistry(selectedMachineId: "local", remoteMachines: [remote])), forKey: "machines")
    let clock = AdvancingServerUpdateScheduler()
    let controller = MachineController(
      store: store,
      projectList: ProjectListModel(
        projectRepository: DefaultProjectRepository(store: InMemoryStore()),
        sessionRepository: DefaultSessionRepository(store: InMemoryStore())
      ),
      clientFactory: { _ in fake },
      updatePollAttempts: pollAttempts,
      updateScheduler: clock.scheduler
    )
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0"))
    return MigrationFixture(controller: controller, center: center, clock: clock, remote: remote)
  }

  @Test("The replacement server's data upgrade shows live in the row, then converges")
  func remoteMigrationProgress() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "1.0", latest: "2.0")
    fake.configureMigration(reports: [
      ServerMigrationProgress(id: "chat", name: "Updating chat history", completed: 10, total: 100),
      ServerMigrationProgress(id: "chat", name: "Updating chat history", completed: 50, total: 100),
    ])
    let fixture = try makeMigrationFixture(fake: fake, pollAttempts: 4)
    let (controller, center, clock, remote) = (fixture.controller, fixture.center, fixture.clock, fixture.remote)
    defer { controller.stopEventSync() }
    await controller.refreshStatus(for: remote.id)
    var rows: [UpdateComponent] = []
    clock.onSleep = {
      if let row = center.components.first(where: { $0.kind == .server }) { rows.append(row) }
    }

    await controller.updateServer(machineId: remote.id)

    #expect(rows.contains { $0.progress == 0.1 && $0.detailText == "Updating chat history 10%" })
    #expect(rows.contains { $0.progress == 0.5 && $0.statusMessage == "Updating chat history" })
    #expect(controller.serverUpdatePhase(for: remote.id) == .idle)
    #expect(controller.connectionsById[remote.id]?.dataUpgradeProgress == nil)
    #expect(controller.availability(for: remote.id) == .ready)
    #expect(controller.statusByMachineId[remote.id]?.isReachable == true)
  }

  @Test("A long single-step migration keeps the wait alive while the server keeps answering")
  func remoteMigrationWithoutGranularProgress() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "1.0", latest: "2.0")
    let step = ServerMigrationProgress(id: "layout", name: "Moving worktrees", completed: 0, total: 0)
    fake.configureMigration(reports: Array(repeating: step, count: 8))
    let fixture = try makeMigrationFixture(fake: fake, pollAttempts: 3)
    let (controller, clock, remote) = (fixture.controller, fixture.clock, fixture.remote)
    defer { controller.stopEventSync() }
    await controller.refreshStatus(for: remote.id)
    var messages: [String] = []
    clock.onSleep = {
      if let message = controller.connectionsById[remote.id]?.updateStatusMessage, messages.last != message {
        messages.append(message)
      }
    }

    await controller.updateServer(machineId: remote.id)

    // Eight migrating polls plus the ready one exceed the three-poll budget
    // several times over; each answer extended the deadline.
    #expect(clock.requestedIntervals.count >= 9)
    #expect(messages.contains("Moving worktrees"))
    #expect(controller.serverUpdatePhase(for: remote.id) == .idle)
    #expect(controller.connectionsById[remote.id]?.updateProgress == nil)
  }

  @Test("A failed data upgrade ends the wait with the server's reason")
  func remoteMigrationFailure() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "1.0", latest: "2.0")
    fake.configureMigration(
      reports: [ServerMigrationProgress(id: "chat", name: "Updating chat history", completed: 1, total: 2)],
      failure: "SQLITE_FULL: database or disk is full")
    let fixture = try makeMigrationFixture(fake: fake, pollAttempts: 4)
    let (controller, center, clock, remote) = (fixture.controller, fixture.center, fixture.clock, fixture.remote)
    defer { controller.stopEventSync() }
    await controller.refreshStatus(for: remote.id)

    await controller.updateServer(machineId: remote.id)

    #expect(controller.serverUpdatePhase(for: remote.id) == .failed("SQLITE_FULL: database or disk is full"))
    #expect(controller.availability(for: remote.id) == .failed("SQLITE_FULL: database or disk is full"))
    #expect(clock.requestedIntervals.count == 2)
    let row = try #require(center.components.first { $0.kind == .server })
    #expect(row.detailText == "Update failed: SQLITE_FULL: database or disk is full")
  }
}
