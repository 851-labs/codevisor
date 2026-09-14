import Foundation
import Testing
@testable import CodevisorCore

extension UpdateCenterTests {
  @Test("Failed harnesses never prevent remote server or local app updates", arguments: [false, true])
  func harnessFailureDoesNotBlockCodevisor(triggerFails: Bool) async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "1.0", latest: "2.0")
    var harness = makeHarness(updateAvailable: true)
    harness.lifecycle = ServerHarnessLifecycleState(phase: "failed", error: "installer failed")
    fake.configureHarnesses([harness])
    if triggerFails {
      fake.harnessUpdateHandler = { _ in throw CodevisorServerClientError.httpStatus(500, "installer failed") }
    }
    let controller = try makeController(fakes: ["local": fake, remote.id: fake], remotes: [remote])
    defer { controller.stopEventSync() }
    let app = AppUpdateModel(currentVersion: "1.0")
    app.checkHandler = { _ in }
    app.reportAvailable(version: "2.0", releasePageURL: nil)
    var installs = 0
    app.installHandler = { _ in installs += 1 }
    let center = UpdateCenter(machines: controller, appUpdate: app)
    await center.refresh()

    await center.updateAll()

    #expect(fake.appliedUpdates == 1)
    #expect(installs == 1)
    #expect(center.updateAllNotice == nil)
    #expect(center.components.filter { $0.kind == .harness }.allSatisfy { $0.isFailed })
  }

  @Test("Check Again clears failures immediately and old lifecycle reports stay dismissed")
  func checkAgainResetsFailures() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureUpdate(current: "1.0", latest: "2.0")
    fake.configureBusy(true)
    var harness = makeHarness(updateAvailable: true)
    harness.lifecycle = ServerHarnessLifecycleState(phase: "failed", error: "old failure", startedAt: "attempt-1")
    fake.configureHarnesses([harness])
    fake.configurePluginUpdates([makePluginUpdate()])
    fake.pluginPrepareError = "plugin failure"
    let controller = try makeController(fakes: [remote.id: fake], remotes: [remote])
    defer { controller.stopEventSync() }
    let app = AppUpdateModel(currentVersion: "1.0")
    app.checkHandler = { _ in }
    app.reportAvailable(version: "2.0", releasePageURL: nil)
    let center = UpdateCenter(machines: controller, appUpdate: app)
    await center.refresh()
    await center.updateAll()
    app.reportFailure("app failure")
    controller.markFailed(for: remote.id, message: "restart timed out")
    #expect(center.updateAllNotice != nil)
    #expect(center.components.filter(\.isFailed).count == 4)

    app.checkHandler = { userInitiated in
      #expect(userInitiated)
      #expect(center.updateAllNotice == nil)
      #expect(center.components.allSatisfy { !$0.isFailed })
      #expect(app.progress == nil)
      app.reportAvailable(version: "2.0", releasePageURL: nil)
    }
    await center.refresh(force: true)
    #expect(controller.connectionsById[remote.id]?.availability == .ready)
    await center.refresh()
    #expect(center.components.allSatisfy { !$0.isFailed })

    // Retrying can report even the same failure again.
    let row = try #require(center.components.first { $0.kind == .harness })
    await center.update(row)
    #expect(center.components.first { $0.kind == .harness }?.isFailed == true)
    await center.refresh(force: true)
    harness.lifecycle?.startedAt = "attempt-2"
    fake.configureHarnesses([harness])
    await center.refresh()
    #expect(center.components.first { $0.kind == .harness }?.isFailed == true)
  }

  @Test("Check Again preserves active updates and their progress")
  func checkAgainPreservesActiveUpdates() async throws {
    let controller = try makeController(fakes: [:], remotes: [])
    defer { controller.stopEventSync() }
    let connection = controller.connection(for: "local")
    connection.updatePhase = .updating
    connection.updateStatusMessage = "Downloading…"
    connection.updateProgress = 0.5
    let app = AppUpdateModel(currentVersion: "1.0")
    app.checkHandler = { _ in Issue.record("An active install must not start a check") }
    app.reportInstalling(version: "2.0", releasePageURL: nil)
    app.reportProgress("Downloading…", fraction: 0.4)
    let center = UpdateCenter(machines: controller, appUpdate: app)

    await center.refresh(force: true)

    #expect(app.isUpdating)
    #expect(app.progress == 0.4)
    #expect(connection.updatePhase == .updating)
    #expect(connection.updateProgress == 0.5)
  }
}
