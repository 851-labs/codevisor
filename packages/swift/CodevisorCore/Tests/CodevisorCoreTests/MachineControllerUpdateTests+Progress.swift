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
