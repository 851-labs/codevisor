import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

/// Freshness and scope of update checks, and row state across a harness
/// update's round trip.
extension UpdateCenterTests {
  func makeHarness(id: String) -> ServerHarness {
    var harness = makeHarness(updateAvailable: true)
    harness.id = id
    harness.name = id
    return harness
  }

  @Test("A forced check covers only the shared harness list")
  func forcedCheckIsScopedToListedHarnesses() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureHarnesses([makeHarness(id: "claude-code"), makeHarness(id: "codex")])
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    defer { controller.stopEventSync() }
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0.0"))
    center.listedHarnessIds = { ["claude-code"] }

    await center.refresh(force: true)

    #expect(fake.harnessCheckScopes == [["claude-code"]])
    #expect(center.components.filter { $0.kind == .harness }.map(\.id) == ["harness:remote-a:claude-code"])
  }

  @Test("A forced check requested during a plain sweep still asks every feed afresh")
  func forcedCheckWaitsForSweepThenRuns() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureHarnesses([makeHarness(updateAvailable: true)])
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    defer { controller.stopEventSync() }
    await controller.refreshStatus(for: remote.id)
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0.0"))
    let reading = TestSignal()
    let release = TestSignal()
    fake.harnessReadGate = {
      reading.signal()
      await release.wait()
    }

    let sweep = Task { await center.refresh() }
    await reading.wait()
    let check = Task { await center.refresh(force: true) }
    // The request is visible (and blocking) while it waits for the sweep.
    await awaitObserved { center.isCheckingForUpdates }
    #expect(fake.harnessCheckScopes.isEmpty)

    release.signal()
    await sweep.value
    await check.value

    #expect(fake.harnessCheckScopes.count == 1)
    #expect(!center.isCheckingForUpdates)
  }

  @Test("A harness update stays in progress from the click until the machine reports back")
  func harnessUpdateNeverFlashesTheButton() async throws {
    let remote = makeRemote("remote-a")
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureHarnesses([makeHarness(updateAvailable: true)])
    fake.harnessUpdateHandler = { _ in
      ServerHarnessOperationStarted(
        accepted: true,
        lifecycle: ServerHarnessLifecycleState(phase: "pendingUpdate")
      )
    }
    let controller = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    defer { controller.stopEventSync() }
    await controller.refreshStatus(for: remote.id)
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0.0"))
    await center.refresh()
    let row = try #require(center.components.first { $0.kind == .harness })
    let reading = TestSignal()
    let release = TestSignal()
    fake.harnessReadGate = {
      reading.signal()
      await release.wait()
    }

    let update = Task { await center.update(row) }
    // Accepted, and the inventory re-read is still in flight: the row must
    // already show the machine's state, not fall back to "Update".
    await reading.wait()
    let inFlight = try #require(center.components.first { $0.id == row.id })
    #expect(inFlight.phase == .updating)
    #expect(inFlight.statusMessage == "Waiting for chats to finish…")

    release.signal()
    await update.value
  }
}
