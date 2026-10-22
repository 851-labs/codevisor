import ACPKit
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("UpdateCenter")
struct UpdateCenterTests {
  func makeRemote(_ id: String) -> CodevisorMachine {
    accountMachine(id)
  }

  func makeController(
    fakes: [String: SyncFakeServerClient],
    remotes: [CodevisorMachine]
  ) throws -> MachineController {
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      clientFactory: { machine in
        fakes[machine.id] ?? SyncFakeServerClient(projects: [], sessions: [])
      },
      updatePollInterval: .milliseconds(2),
      updatePollAttempts: 50,
      updateScheduler: AdvancingServerUpdateScheduler().scheduler
    )
    signIn(controller, machines: remotes)
    return controller
  }

  func makeHarness(updateAvailable: Bool) -> ServerHarness {
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

  func makePluginUpdate() -> ServerPluginUpdateStatus {
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
        "harness:cloud:remote-a:claude-code",
        "plugin:cloud:remote-a:notes",
        "server:cloud:remote-a",
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
    appUpdate.checkHandler = {}
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

    #expect(
      fake.operationLog == [
        "plugin.prepare:notes",
        "plugin.apply:notes",
        "update.run:claude-code+server",
        "harness.update:claude-code",
        "server.apply",
      ])
    #expect(appInstalledAfterOperations == 5)
    controller.stopEventSync()
  }

  @Test("updateAll leaves a major-version harness update for its own confirmed click")
  func updateAllSkipsMajorUpdates() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    var major = makeHarness(updateAvailable: true)
    major.updateInfo?.latestVersion = "2.0.0"
    major.updateInfo?.notes = "Plugins stop working."
    fake.configureHarnesses([major])
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0.0"))
    await controller.refreshStatus(for: remote.id)
    await center.refresh()
    let component = try #require(center.components.first { $0.subjectId == "claude-code" })
    #expect(component.notes == "Plugins stop working.")

    await center.updateAll()
    #expect(!fake.operationLog.contains("harness.update:claude-code"))
    await center.update(component)
    #expect(fake.operationLog.contains("harness.update:claude-code"))
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
    appUpdate.checkHandler = {}
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
    appUpdate.checkHandler = {}
    appUpdate.installHandler = { _ in }
    appUpdate.reportAvailable(version: "2.0.0", releasePageURL: nil)
    let center = UpdateCenter(machines: controller, appUpdate: appUpdate, store: store)

    await center.updateAll()
    #expect(store.loadData(forKey: "updateCenter.pendingSession") != nil)

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
      JSONEncoder().encode(["harness:cloud:remote-a:claude-code"]),
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

  @Test("updateAll pauses a machine's chats once for its harnesses and its server restart")
  func updateAllPausesOnceForHarnessesAndServer() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    fake.configureHarnesses([makeHarness(updateAvailable: true)])
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    defer { controller.stopEventSync() }
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0.0"))
    await controller.refreshStatus(for: remote.id)
    await center.refresh()

    await center.updateAll()

    #expect(fake.operationLog == ["update.run:claude-code+server", "harness.update:claude-code", "server.apply"])
    #expect(fake.appliedUpdates == 1)
    #expect(center.updateAllNotice == nil)
  }

  @Test("updateAll keeps this Mac's chats paused from its harness updates into the app update")
  func updateAllHoldsThePauseForTheApp() async throws {
    let local = SyncFakeServerClient(projects: [], sessions: [])
    local.configureHarnesses([makeHarness(updateAvailable: true)])
    local.configureUpdateRunInProgress(polls: 2)
    let controller = try makeController(fakes: ["local": local], remotes: [])
    defer { controller.stopEventSync() }
    let appUpdate = AppUpdateModel(currentVersion: "1.0.0")
    appUpdate.checkHandler = {}
    var operationsBeforeApp: [String]?
    appUpdate.installHandler = { _ in operationsBeforeApp = local.operationLog }
    appUpdate.reportAvailable(version: "2.0.0", releasePageURL: nil)
    let center = UpdateCenter(
      machines: controller,
      appUpdate: appUpdate,
      updateRunPollInterval: .milliseconds(1)
    )
    await center.refresh()

    await center.updateAll()

    #expect(operationsBeforeApp == ["update.run:claude-code+hold", "harness.update:claude-code"])
    #expect(local.operationLog.count == 2)
  }

  @Test("updateAll lets this Mac's chats continue when an earlier failure stops the app update")
  func updateAllReleasesTheHeldPauseOnFailure() async throws {
    let remote = makeRemote("remote-a")
    let remoteFake = SyncFakeServerClient(projects: [], sessions: [])
    remoteFake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    remoteFake.configureBusy(true)
    let local = SyncFakeServerClient(projects: [], sessions: [])
    local.configureHarnesses([makeHarness(updateAvailable: true)])
    let controller = try makeController(fakes: ["local": local, remote.id: remoteFake], remotes: [remote])
    defer { controller.stopEventSync() }
    let appUpdate = AppUpdateModel(currentVersion: "1.0.0")
    appUpdate.checkHandler = {}
    var appInstalls = 0
    appUpdate.installHandler = { _ in appInstalls += 1 }
    appUpdate.reportAvailable(version: "2.0.0", releasePageURL: nil)
    let center = UpdateCenter(machines: controller, appUpdate: appUpdate)
    await controller.refreshStatus(for: remote.id)
    await center.refresh()

    await center.updateAll()

    #expect(appInstalls == 0)
    #expect(
      local.operationLog == ["update.run:claude-code+hold", "harness.update:claude-code", "restart.drain.cancel"])
    #expect(center.updateAllNotice?.contains("remote-a") == true)
  }

  @Test("updateAll updates an older server's harnesses one by one")
  func updateAllFallsBackForOlderServers() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureHarnesses([makeHarness(updateAvailable: true)])
    fake.updateRunUnsupported = true
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    defer { controller.stopEventSync() }
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0.0"))
    await controller.refreshStatus(for: remote.id)
    await center.refresh()

    await center.updateAll()

    #expect(fake.operationLog == ["harness.update:claude-code"])
  }

  @Test("updateAll stops before restarting the app when an earlier step failed")
  func updateAllHaltsOnFailure() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    fake.configureBusy(true)
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    let store = InMemoryStore()
    let appUpdate = AppUpdateModel(currentVersion: "1.0.0")
    appUpdate.checkHandler = {}
    var appInstalls = 0
    appUpdate.installHandler = { _ in appInstalls += 1 }
    appUpdate.reportAvailable(version: "2.0.0", releasePageURL: nil)
    let center = UpdateCenter(machines: controller, appUpdate: appUpdate, store: store)
    await controller.refreshStatus(for: remote.id)
    await center.refresh()

    await center.updateAll()

    #expect(appInstalls == 0)
    #expect(center.updateAllNotice?.contains("remote-a") == true)
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

    fake.configureHarnesses([makeHarness(updateAvailable: false)])
    center.noteHarnessLifecycleChanged(onServer: remote.id)
    await awaitObserved { center.availableCount == 0 }
    #expect(center.availableCount == 0)
    controller.stopEventSync()
  }
}

extension UpdateCenterTests {
  @Test("Machine groups put each machine's Codevisor first, then harnesses, then plugins")
  func machineGroups() async throws {
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
    appUpdate.checkHandler = {}
    let center = UpdateCenter(machines: controller, appUpdate: appUpdate)

    await controller.refreshStatus(for: remote.id)
    await center.refresh()

    let groups = center.machineGroups
    #expect(groups.map(\.id) == ["local", "cloud:remote-a"])
    #expect(groups.first?.isLocal == true)
    #expect(groups.first?.codevisor?.kind == .app)
    #expect(groups.first?.codevisor?.title == "Codevisor")
    #expect(groups.first?.codevisor?.detailText == "1.0.0")
    #expect(groups.first?.components.isEmpty == true)
    #expect(groups.last?.codevisor?.kind == .server)
    #expect(groups.last?.codevisor?.title == "Codevisor")
    #expect(groups.last?.codevisor?.detailText == "0.1.0 → 0.2.0")
    #expect(groups.last?.codevisor?.pendingVersionChange?.latest == "0.2.0")
    #expect(groups.last?.components.map(\.kind) == [.harness, .plugin])
    #expect(groups.last?.availableCount == 3)
    #expect(groups.last?.components.map(\.detailText) == ["1.0.0 → 1.2.0", "1.0.0 → 1.1.0"])
    controller.stopEventSync()
  }

  @Test("A failed row summarizes its first output line; an updating row shows its status")
  func detailTextStates() {
    var component = UpdateComponent(
      id: "server:m",
      kind: .server,
      machineId: "m",
      machineName: "m",
      subjectId: "",
      title: "Codevisor Server",
      installedVersion: "0.1.0",
      latestVersion: "0.2.0",
      updateAvailable: true,
      phase: .failed("ld: symbol not found\nsecond line\nthird line")
    )
    #expect(component.detailText == "Update failed: ld: symbol not found")
    #expect(component.isFailed)
    #expect(component.pendingVersionChange == nil)
    component = UpdateComponent(
      id: "app",
      kind: .app,
      machineId: "local",
      machineName: "local",
      subjectId: "",
      title: "Codevisor",
      installedVersion: "0.1.0",
      latestVersion: "0.2.0",
      updateAvailable: true,
      phase: .updating,
      statusMessage: "Downloading…",
      progress: 0.42
    )
    #expect(component.detailText == "Downloading… 42%")
    #expect(component.pendingVersionChange == nil)
  }

  @Test("refresh probes machines that have never reported status before sweeping them")
  func refreshProbesUnknownMachines() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    fake.configureHarnesses([makeHarness(updateAvailable: true)])
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0.0"))
    #expect(controller.connectionsById[remote.id]?.status == nil)

    await center.refresh(force: true)

    #expect(controller.connectionsById[remote.id]?.status?.isReachable == true)
    #expect(center.components.map(\.id).sorted() == ["harness:cloud:remote-a:claude-code", "server:cloud:remote-a"])
    controller.stopEventSync()
  }
}
