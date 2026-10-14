import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension MachineController {
  func serverUpdatePhase(for machineId: String) -> ServerUpdatePhase {
    connectionsById[machineId]?.updatePhase ?? .idle
  }

  func serverUpdateInfo(for machineId: String) -> ServerUpdateInfo? {
    connectionsById[machineId]?.updateInfo
  }
}

@MainActor
@Suite("MachineController server updates")
struct MachineControllerUpdateTests {
  @Test("Client-triggered server update waits for the restart and reconnects")
  func remoteServerUpdate() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    let projectList = ProjectListModel.fixture()
    let clock = AdvancingServerUpdateScheduler()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { _ in fake },
      updatePollInterval: .milliseconds(2),
      updatePollAttempts: 50,
      updateScheduler: clock.scheduler
    )

    await controller.refreshStatus(for: "local")
    #expect(controller.serverUpdateInfo(for: "local")?.updateAvailable == true)
    #expect(controller.serverUpdateInfo(for: "local")?.latestVersion == "0.2.0")

    await controller.updateServer(machineId: "local")

    #expect(fake.appliedUpdates == 1)
    #expect(controller.serverUpdatePhase(for: "local") == .idle)
    #expect(controller.serverUpdateInfo(for: "local")?.updateAvailable == false)
    #expect(controller.statusByMachineId["local"]?.label.contains("0.2.0") == true)
    controller.stopEventSync()

    await controller.updateServer(machineId: "local")
    #expect(controller.serverUpdatePhase(for: "local") == .idle)
    #expect(fake.appliedUpdates == 2)
  }

  @Test("Update checks and installs follow the app's release channel")
  func remoteServerUpdateChannel() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    let projectList = ProjectListModel.fixture()
    let clock = AdvancingServerUpdateScheduler()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { _ in fake },
      updatePollInterval: .milliseconds(2),
      updatePollAttempts: 50,
      updateScheduler: clock.scheduler
    )
    defer { controller.stopEventSync() }

    await controller.refreshStatus(for: "local")
    #expect(fake.updateInfoChannels == [.stable])

    controller.serverUpdateChannel = .alpha
    await controller.refreshStatus(for: "local")
    #expect(fake.updateInfoChannels.last == .alpha)
    await controller.updateServer(machineId: "local")
    #expect(fake.appliedChannels == [.alpha])
  }

  @Test("Remote update accepts a channel-current runtime whose version string differs")
  func remoteServerUpdateVersionMismatch() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(
      current: "0.1.97",
      latest: "0.1.97-alpha.55",
      installedVersion: "0.1.97"
    )
    let projectList = ProjectListModel.fixture()
    let clock = AdvancingServerUpdateScheduler()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { _ in fake },
      updatePollInterval: .milliseconds(2),
      updatePollAttempts: 50,
      updateScheduler: clock.scheduler
    )
    defer { controller.stopEventSync() }
    controller.serverUpdateChannel = .alpha

    await controller.refreshStatus(for: "local")
    await controller.updateServer(machineId: "local")

    #expect(controller.serverUpdatePhase(for: "local") == .idle)
    #expect(controller.serverUpdateInfo(for: "local")?.updateAvailable == false)
    #expect(controller.statusByMachineId["local"]?.label.contains("0.1.97") == true)
  }

  @Test("Build numbers confirm convergence when version strings differ")
  func remoteServerUpdateBuildNumberConvergence() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(
      current: "0.1.97",
      latest: "0.1.97-alpha.55",
      installedVersion: "0.1.97",
      currentBuildNumber: 100,
      targetBuildNumber: 200
    )
    let projectList = ProjectListModel.fixture()
    let clock = AdvancingServerUpdateScheduler()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { _ in fake },
      updatePollInterval: .milliseconds(2),
      updatePollAttempts: 50,
      updateScheduler: clock.scheduler
    )
    defer { controller.stopEventSync() }
    controller.serverUpdateChannel = .alpha

    await controller.refreshStatus(for: "local")
    #expect(controller.serverUpdateInfo(for: "local")?.latestBuildNumber == 200)
    await controller.updateServer(machineId: "local")

    #expect(fake.appliedUpdates == 1)
    #expect(controller.serverUpdatePhase(for: "local") == .idle)
    #expect(controller.serverUpdateInfo(for: "local")?.updateAvailable == false)
  }

  @Test("A failed unattended install surfaces the machine's reason")
  func remoteServerUpdateHandoffFailure() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    fake.configureApplyFailure(message: "Sparkle could not verify the update signature.")
    let projectList = ProjectListModel.fixture()
    let clock = AdvancingServerUpdateScheduler()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { _ in fake },
      updatePollInterval: .milliseconds(2),
      updatePollAttempts: 50,
      updateScheduler: clock.scheduler
    )
    defer { controller.stopEventSync() }

    await controller.refreshStatus(for: "local")
    await controller.updateServer(machineId: "local")

    #expect(fake.appliedUpdates == 1)
    if case let .failed(message) = controller.serverUpdatePhase(for: "local") {
      #expect(message.contains("signature"))
    } else {
      Issue.record("Expected a failed phase, got \(controller.serverUpdatePhase(for: "local"))")
    }
  }

  @Test("A server draining live chats keeps the update in progress until it restarts")
  func remoteServerUpdateDrains() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    fake.configureDrain(polls: 12)
    let projectList = ProjectListModel.fixture()
    let clock = AdvancingServerUpdateScheduler()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { _ in fake },
      updatePollInterval: .milliseconds(2),
      updatePollAttempts: 5,
      updateScheduler: clock.scheduler
    )
    defer { controller.stopEventSync() }
    await controller.refreshStatus(for: "local")

    var messages: [String] = []
    clock.onSleep = { [weak controller] in
      if let message = controller?.connectionsById["local"]?.updateStatusMessage,
        messages.last != message
      {
        messages.append(message)
      }
    }
    await controller.updateServer(machineId: "local")

    #expect(clock.elapsed > .milliseconds(10))
    #expect(controller.serverUpdatePhase(for: "local") == .idle)
    #expect(controller.serverUpdateInfo(for: "local")?.updateAvailable == false)
    #expect(messages.contains { $0.contains("Waiting for 2 chats to finish") })
    #expect(controller.connectionsById["local"]?.updateStatusMessage == nil)
  }

  @Test("A busy server declines the update with a clear message")
  func remoteServerUpdateRefusedWhileBusy() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    fake.configureBusy(true)
    let projectList = ProjectListModel.fixture()
    let clock = AdvancingServerUpdateScheduler()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { _ in fake },
      updatePollInterval: .milliseconds(2),
      updatePollAttempts: 50,
      updateScheduler: clock.scheduler
    )
    defer { controller.stopEventSync() }

    await controller.updateServer(machineId: "local")

    if case let .failed(message) = controller.serverUpdatePhase(for: "local") {
      #expect(message.contains("chats running"))
    } else {
      Issue.record("Expected a failed phase, got \(controller.serverUpdatePhase(for: "local"))")
    }
  }

  @Test("An unreachable restart times out once draining ends", arguments: [0, 12])
  func remoteServerUpdateTimesOut(drainPolls: Int) async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    fake.configureDrain(polls: drainPolls)
    fake.configureRestartDowntime(polls: 4)
    let clock = AdvancingServerUpdateScheduler()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      clientFactory: { _ in fake },
      updatePollInterval: .milliseconds(2),
      updatePollAttempts: 3,
      updateScheduler: clock.scheduler
    )
    defer { controller.stopEventSync() }
    await controller.refreshStatus(for: "local")

    await controller.updateServer(machineId: "local")

    let expectedPolls = max(drainPolls - 1, 0) + 3
    #expect(clock.requestedIntervals.count == expectedPolls)
    #expect(clock.elapsed == .milliseconds(2) * expectedPolls)
    #expect(
      controller.serverUpdatePhase(for: "local")
        == .failed("The server did not come back after updating. Check it on the machine directly."))
    #expect(controller.serverUpdateInfo(for: "local")?.updateAvailable == true)
    #expect(controller.connectionsById["local"]?.updateStatusMessage == nil)
  }

  @Test("Elapsed time can exhaust the deadline before all probes run")
  func remoteServerUpdateDeadlineIncludesDelays() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    let clock = AdvancingServerUpdateScheduler()
    clock.onSleep = { [weak clock] in clock?.advance(by: .milliseconds(10)) }
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      clientFactory: { _ in fake },
      updatePollInterval: .milliseconds(2),
      updatePollAttempts: 5,
      updateScheduler: clock.scheduler
    )
    defer { controller.stopEventSync() }
    await controller.refreshStatus(for: "local")

    await controller.updateServer(machineId: "local")

    #expect(clock.requestedIntervals == [.milliseconds(2)])
    #expect(clock.elapsed == .milliseconds(12))
    #expect(
      controller.serverUpdatePhase(for: "local")
        == .failed("The server did not come back after updating. Check it on the machine directly."))
  }
}
