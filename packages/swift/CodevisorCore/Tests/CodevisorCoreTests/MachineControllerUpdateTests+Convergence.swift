import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

/// Convergence follows the install that actually lands, and a machine that
/// answers after the wait is never left latched behind a closed gate.
extension MachineControllerUpdateTests {
  private func makeController(
    fake: SyncFakeServerClient, attempts: Int, clock: AdvancingServerUpdateScheduler
  ) -> MachineController {
    MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel(
        projectRepository: DefaultProjectRepository(store: InMemoryStore()),
        sessionRepository: DefaultSessionRepository(store: InMemoryStore())
      ),
      clientFactory: { _ in fake },
      updatePollInterval: .milliseconds(2),
      updatePollAttempts: attempts,
      updateScheduler: clock.scheduler
    )
  }

  @Test("Convergence follows the build the machine reports installing")
  func remoteServerUpdateConvergesOnReportedBuild() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    // The check promised 661; the machine's installer resumes a staged 660.
    fake.configureUpdate(
      current: "0.1.102",
      latest: "0.1.102-alpha.661",
      installedVersion: "0.1.102",
      currentBuildNumber: 659,
      targetBuildNumber: 661,
      installedBuildNumber: 660
    )
    fake.applyProgressReports = [
      ServerUpdateApplyState(
        state: "installing", message: "Installing…", targetVersion: "0.1.102-alpha.660",
        targetBuildNumber: 660, at: "2026-06-30T00:00:03.000Z")
    ]
    let clock = AdvancingServerUpdateScheduler()
    let controller = makeController(fake: fake, attempts: 50, clock: clock)
    controller.serverUpdateChannel = .alpha
    defer { controller.stopEventSync() }
    await controller.refreshStatus(for: "local")

    await controller.updateServer(machineId: "local")

    #expect(fake.appliedUpdates == 1)
    #expect(controller.serverUpdatePhase(for: "local") == .idle)
    #expect(controller.connectionsById["local"]?.availability == .ready)
    #expect(controller.statusByMachineId["local"]?.isReachable == true)
  }

  @Test("A restart that lands as the wait ends still converges")
  func remoteServerUpdateLateRestartConverges() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    // Down for exactly as many probes as the budget allows.
    fake.configureRestartDowntime(polls: 3)
    let clock = AdvancingServerUpdateScheduler()
    let controller = makeController(fake: fake, attempts: 3, clock: clock)
    defer { controller.stopEventSync() }
    await controller.refreshStatus(for: "local")

    await controller.updateServer(machineId: "local")

    #expect(controller.serverUpdatePhase(for: "local") == .idle)
    #expect(controller.serverUpdateInfo(for: "local")?.updateAvailable == false)
    #expect(controller.connectionsById["local"]?.availability == .ready)
  }

  @Test("A machine back on an older build than requested stays usable and says so")
  func remoteServerUpdateShortOfTargetIsNotLatched() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(
      current: "0.1.102",
      latest: "0.1.102-alpha.661",
      installedVersion: "0.1.102",
      currentBuildNumber: 659,
      targetBuildNumber: 661,
      installedBuildNumber: 660
    )
    let clock = AdvancingServerUpdateScheduler()
    let controller = makeController(fake: fake, attempts: 6, clock: clock)
    controller.serverUpdateChannel = .alpha
    defer { controller.stopEventSync() }
    await controller.refreshStatus(for: "local")

    await controller.updateServer(machineId: "local")

    guard case let .failed(message) = controller.serverUpdatePhase(for: "local") else {
      Issue.record("Expected a failed phase, got \(controller.serverUpdatePhase(for: "local"))")
      return
    }
    #expect(
      message
        == "The server restarted into 0.1.102-alpha.660, but 0.1.102-alpha.661 is still available. Try updating again.")
    // Reachable, not gated: the next request must not bounce off a failure.
    #expect(controller.connectionsById["local"]?.availability == .ready)
    #expect(controller.serverUpdateInfo(for: "local")?.updateAvailable == true)
    #expect(controller.serverUpdateInfo(for: "local")?.currentBuildNumber == 660)
  }

  @Test("A reachable machine that never restarted is reported as such")
  func remoteServerUpdateNeverRestarted() {
    let before = ServerHealth(ok: true, version: "0.1.0", database: "ready", bootId: "a", buildNumber: 10)
    #expect(
      MachineController.notConvergedMessage(initial: before, current: before, refreshed: nil)
        == "The server is still running the previous version and never restarted. Check it on the machine directly.")
    let rebooted = ServerHealth(ok: true, version: "0.1.1", database: "ready", bootId: "b", buildNumber: 10)
    #expect(
      MachineController.notConvergedMessage(initial: before, current: rebooted, refreshed: nil)
        == "The server restarted into 0.1.1, but a newer release is still available. Try updating again.")
  }
}
