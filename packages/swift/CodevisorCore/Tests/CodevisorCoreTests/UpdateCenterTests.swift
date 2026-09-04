import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

/// The fleet-wide update fold: components across machines, per-row actions,
/// and the ordered update-all.
@MainActor
@Suite("UpdateCenter")
struct UpdateCenterTests {
  private func makeRemote(_ id: String) -> CodevisorMachine {
    CodevisorMachine(
      id: id,
      name: id,
      baseURL: URL(string: "http://\(id).test:49361")!,
      kind: "remote"
    )
  }

  private func makeController(
    fakes: [String: SyncFakeServerClient],
    remotes: [CodevisorMachine]
  ) throws -> MachineController {
    let store = InMemoryStore()
    try store.saveData(
      JSONEncoder().encode(
        MachineRegistry(selectedMachineId: "local", remoteMachines: remotes)
      ),
      forKey: "machines"
    )
    return MachineController(
      store: store,
      projectList: ProjectListModel(
        projectRepository: DefaultProjectRepository(store: InMemoryStore()),
        sessionRepository: DefaultSessionRepository(store: InMemoryStore())
      ),
      clientFactory: { machine in
        fakes[machine.id] ?? SyncFakeServerClient(projects: [], sessions: [])
      },
      updatePollInterval: .milliseconds(2),
      updatePollAttempts: 50
    )
  }

  private func makeHarness(updateAvailable: Bool) -> ServerHarness {
    ServerHarness(
      id: "claude-code",
      name: "Claude Code",
      symbolName: "sparkles",
      source: "builtin",
      launchKind: "cli",
      enabled: true,
      readiness: ServerHarnessReadiness(state: "ready", version: "1.0.0"),
      updateInfo: ServerHarnessUpdateInfo(
        installedVersion: "1.0.0",
        latestVersion: updateAvailable ? "1.2.0" : "1.0.0",
        updateAvailable: updateAvailable
      )
    )
  }

  private func makePluginUpdate() -> ServerPluginUpdateStatus {
    ServerPluginUpdateStatus(
      pluginId: "notes",
      installedVersion: "1.0.0",
      state: .available,
      checkedAt: "2026-06-30T00:00:00.000Z",
      registryVersion: "1.1.0"
    )
  }

  @Test("Components fold servers, harnesses, and plugins across machines")
  func componentsFold() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    fake.configureHarnesses([makeHarness(updateAvailable: true)])
    fake.configurePluginUpdates([makePluginUpdate()])
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    let center = UpdateCenter(
      machines: controller,
      appUpdate: AppUpdateModel(currentVersion: "1.0.0")
    )

    await controller.refreshStatus(for: remote.id)
    await center.refresh()

    let ids = center.components.map(\.id).sorted()
    #expect(
      ids == [
        "harness:remote-a:claude-code",
        "plugin:remote-a:notes",
        "server:remote-a",
      ])
    #expect(center.availableCount == 3)
    let server = center.components.first { $0.kind == .server }
    #expect(server?.machineName == "remote-a")
    #expect(server?.latestVersion == "0.2.0")
    controller.stopEventSync()
  }

  @Test("updateAll runs plugins, then harnesses, then servers, app last")
  func updateAllOrder() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    fake.configureHarnesses([makeHarness(updateAvailable: true)])
    fake.configurePluginUpdates([makePluginUpdate()])
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    let appUpdate = AppUpdateModel(currentVersion: "1.0.0")
    appUpdate.checkHandler = { _ in }
    var appInstalledAfterOperations: Int?
    appUpdate.installHandler = { _ in
      appInstalledAfterOperations = fake.operationLog.count
    }
    appUpdate.reportAvailable(version: "2.0.0", releasePageURL: nil)
    let center = UpdateCenter(machines: controller, appUpdate: appUpdate)

    await controller.refreshStatus(for: remote.id)
    await center.refresh()
    #expect(center.availableCount == 4)

    await center.updateAll()

    // Restart-free components first, then the remote server, then the
    // app — whose install restarts this client.
    #expect(
      fake.operationLog == [
        "plugin.prepare:notes",
        "plugin.apply:notes",
        "harness.update:claude-code",
        "server.apply",
      ])
    #expect(appInstalledAfterOperations == 4)
    controller.stopEventSync()
  }

  @Test("The app row shows the Alpha release identity on the Alpha channel")
  func appAlphaVersion() throws {
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: [])],
      remotes: []
    )
    let appUpdate = AppUpdateModel(
      currentVersion: "1.2.3",
      currentBuildNumber: 42,
      allowsAlphaUpdates: true
    )
    appUpdate.checkHandler = { _ in }
    let center = UpdateCenter(machines: controller, appUpdate: appUpdate)

    #expect(center.components.first?.installedVersion == "1.2.3-alpha.42")
    controller.stopEventSync()
  }

  @Test("A remote server row shows the installed Alpha release identity")
  func remoteServerAlphaVersion() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(
      current: "1.2.3",
      latest: "1.2.3-alpha.43",
      currentBuildNumber: 42,
      targetBuildNumber: 43
    )
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    controller.serverUpdateChannel = .alpha
    let center = UpdateCenter(
      machines: controller,
      appUpdate: AppUpdateModel(currentVersion: "1.2.3")
    )

    await controller.refreshStatus(for: remote.id)

    #expect(center.components.first?.installedVersion == "1.2.3-alpha.42")
    controller.stopEventSync()
  }

  @Test("An older remote server without build metadata keeps its base version")
  func olderRemoteServerAlphaVersion() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "1.2.3", latest: "1.2.3-alpha.43")
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    controller.serverUpdateChannel = .alpha
    let center = UpdateCenter(
      machines: controller,
      appUpdate: AppUpdateModel(currentVersion: "1.2.3")
    )

    await controller.refreshStatus(for: remote.id)

    #expect(center.components.first?.installedVersion == "1.2.3")
    controller.stopEventSync()
  }

  @Test("updateAll clears its session when no app restart is pending")
  func sessionClearsWithoutAppRestart() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureHarnesses([makeHarness(updateAvailable: true)])
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    let store = InMemoryStore()
    let center = UpdateCenter(
      machines: controller,
      appUpdate: AppUpdateModel(currentVersion: "1.0.0"),
      store: store
    )
    await controller.refreshStatus(for: remote.id)
    await center.refresh()

    await center.updateAll()

    #expect(store.loadData(forKey: "updateCenter.pendingSession") == nil)
    controller.stopEventSync()
  }

  @Test("An app update leaves the session for the relaunched client")
  func appUpdateLeavesSessionForRelaunch() async throws {
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: [])],
      remotes: []
    )
    let store = InMemoryStore()
    let appUpdate = AppUpdateModel(currentVersion: "1.0.0")
    appUpdate.checkHandler = { _ in }
    appUpdate.installHandler = { _ in }
    appUpdate.reportAvailable(version: "2.0.0", releasePageURL: nil)
    let center = UpdateCenter(machines: controller, appUpdate: appUpdate, store: store)

    await center.updateAll()
    // Sparkle is about to restart this client: the marker survives.
    #expect(store.loadData(forKey: "updateCenter.pendingSession") != nil)

    // The relaunched app consumes it: surface reopens, session clears.
    let relaunched = UpdateCenter(
      machines: controller,
      appUpdate: AppUpdateModel(currentVersion: "2.0.0"),
      store: store
    )
    await relaunched.resumePendingSessionIfNeeded()
    #expect(store.loadData(forKey: "updateCenter.pendingSession") == nil)
    controller.stopEventSync()
  }

  @Test("A crashed run's session resumes what is still pending")
  func resumesPendingSession() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureHarnesses([makeHarness(updateAvailable: true)])
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    let store = InMemoryStore()
    try store.saveData(
      JSONEncoder().encode(["harness:remote-a:claude-code"]),
      forKey: "updateCenter.pendingSession"
    )
    let center = UpdateCenter(
      machines: controller,
      appUpdate: AppUpdateModel(currentVersion: "1.0.0"),
      store: store
    )
    await controller.refreshStatus(for: remote.id)

    await center.resumePendingSessionIfNeeded()

    #expect(fake.operationLog.contains("harness.update:claude-code"))
    #expect(store.loadData(forKey: "updateCenter.pendingSession") == nil)
    controller.stopEventSync()
  }

  @Test("updateAll waits for a machine's harness updates to settle before its server restarts")
  func updateAllWaitsForHarnessSettle() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    fake.configureHarnesses([makeHarness(updateAvailable: true)])
    // The triggered harness update keeps running on the machine for the
    // next three inventory reads before it settles.
    fake.configureHarnessUpdateInProgress(polls: 3)
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    let center = UpdateCenter(
      machines: controller,
      appUpdate: AppUpdateModel(currentVersion: "1.0.0"),
      harnessSettlePollInterval: .milliseconds(1),
      harnessSettleAttempts: 50
    )
    await controller.refreshStatus(for: remote.id)
    await center.refresh()

    await center.updateAll()

    #expect(fake.operationLog == ["harness.update:claude-code", "server.apply"])
    // The server step only ran once the inventory reported the harness
    // update finished (the harness refresh after the trigger, plus three
    // "still updating" polls, plus the settled read).
    #expect(fake.harnessLifecycleReads >= 4)
    #expect(center.updateAllNotice == nil)
    controller.stopEventSync()
  }

  @Test("updateAll stops before restarting the app when an earlier step failed")
  func updateAllHaltsOnFailure() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    // An old server that still refuses while busy: the server step fails.
    fake.configureBusy(true)
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    let store = InMemoryStore()
    let appUpdate = AppUpdateModel(currentVersion: "1.0.0")
    appUpdate.checkHandler = { _ in }
    var appInstalls = 0
    appUpdate.installHandler = { _ in appInstalls += 1 }
    appUpdate.reportAvailable(version: "2.0.0", releasePageURL: nil)
    let center = UpdateCenter(machines: controller, appUpdate: appUpdate, store: store)
    await controller.refreshStatus(for: remote.id)
    await center.refresh()

    await center.updateAll()

    #expect(appInstalls == 0)
    #expect(center.updateAllNotice?.contains("remote-a") == true)
    // Nothing is left for a relaunch that never happens.
    #expect(store.loadData(forKey: "updateCenter.pendingSession") == nil)
    controller.stopEventSync()
  }

  @Test("Harness lifecycle changes re-read that machine's inventory")
  func lifecycleRefetch() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureHarnesses([makeHarness(updateAvailable: true)])
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    let center = UpdateCenter(
      machines: controller,
      appUpdate: AppUpdateModel(currentVersion: "1.0.0")
    )
    await controller.refreshStatus(for: remote.id)
    await center.refresh()
    #expect(center.availableCount == 1)

    // The machine finished its update: the next lifecycle event makes
    // the row disappear without a full sweep.
    fake.configureHarnesses([makeHarness(updateAvailable: false)])
    center.noteHarnessLifecycleChanged(onServer: remote.id)
    for _ in 0..<200 {
      if center.availableCount == 0 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(center.availableCount == 0)
    controller.stopEventSync()
  }
}
