import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineNavigationRefreshTests {
  @Test("Refresh ends as soon as all machines answer, including failures", arguments: [false, true])
  func finishesWithoutMinimumDelay(fails: Bool) async throws {
    let clock = TestClock()
    let client = ManualRefreshClient(snapshot: {
      if fails { throw URLError(.cannotConnectToHost) }
    })
    let controller = try makeController(local: client)
    defer { controller.stopEventSync() }

    await controller.refreshNavigation(sleep: clock.sleep)

    #expect(client.snapshots.value == 1)
    #expect(clock.pendingCount == 0)
    if fails {
      guard case .stale = controller.navigationSyncStateByMachineId["local"] else {
        Issue.record("A failed refresh must retain its connection warning")
        return
      }
    } else {
      #expect(controller.navigationSyncStateByMachineId["local"] == .current)
    }
  }

  @Test("A stalled machine cannot hold the gesture or block healthy machines", arguments: [false, true])
  func deadlineBoundsSnapshotAndPreparation(preparing: Bool) async throws {
    let clock = TestClock()
    let blocked = TestSignal()
    let release = TestSignal()
    let stall: @Sendable () async -> Void = {
      blocked.signal()
      // Deliberately ignores task cancellation, like a wedged transport.
      await release.wait()
    }
    let client = ManualRefreshClient(
      info: { if preparing { await stall() } },
      snapshot: { if !preparing { await stall() } }
    )
    let healthy = ManualRefreshClient()
    let controller = try makeController(local: client, remote: healthy)
    defer {
      release.signal()
      controller.stopEventSync()
    }
    if preparing { controller.markFailed(for: "local", message: "Unreachable") }
    var finished = false
    let gesture = Task {
      await controller.refreshNavigation(sleep: clock.sleep)
      finished = true
    }
    await blocked.wait()
    await clock.waitForSleep(.seconds(5))
    await awaitObserved { controller.navigationSyncStateByMachineId["healthy"] == .current }
    let operation = try #require(controller.connection(for: "local").manualNavigationRefresh?.task)

    #expect(healthy.snapshots.value == 1)
    clock.advance(by: .milliseconds(4999))
    #expect(!finished)
    clock.advance(by: .milliseconds(1))
    await gesture.value
    #expect(finished)
    #expect(clock.pendingCount == 0)
    #expect(!operation.isCancelled)
    #expect(controller.navigationSyncStateByMachineId["local"] != .current)

    // The result is still applied when the slow machine eventually answers.
    release.signal()
    await operation.value
    #expect(controller.navigationSyncStateByMachineId["local"] == .current)
    #expect(controller.connection(for: "local").manualNavigationRefresh == nil)
  }

  @Test("Repeated pulls reuse stalled work and still refresh healthy machines")
  func repeatedPullsCoalescePerMachine() async throws {
    let clock = TestClock()
    let release = TestSignal()
    let client = ManualRefreshClient(snapshot: { await release.wait() })
    let healthy = ManualRefreshClient()
    let controller = try makeController(local: client, remote: healthy)
    defer {
      release.signal()
      controller.stopEventSync()
    }
    var firstOperation: MachineNavigationRefresh?
    for pull in 1...3 {
      let gesture = Task { await controller.refreshNavigation(sleep: clock.sleep) }
      await clock.waitForSleep(.seconds(5), count: pull)
      await client.snapshots.wait()
      await healthy.snapshots.wait(for: pull)
      await controller.connection(for: "healthy").manualNavigationRefresh?.task?.value
      let operation = controller.connection(for: "local").manualNavigationRefresh
      if pull == 1 { firstOperation = operation }
      #expect(operation === firstOperation)
      clock.advance(by: .seconds(5))
      await gesture.value
    }
    #expect(client.snapshots.value == 1)
    #expect(healthy.snapshots.value == 3)
    let operation = firstOperation?.task
    release.signal()
    await operation?.value
  }

  @Test("Cancelling one gesture ends its wait without cancelling another or shared work")
  func cancelledGestureReturnsImmediately() async throws {
    let clock = TestClock()
    let release = TestSignal()
    let client = ManualRefreshClient(snapshot: { await release.wait() })
    let controller = try makeController(local: client)
    defer {
      release.signal()
      controller.stopEventSync()
    }
    let first = Task { await controller.refreshNavigation(sleep: clock.sleep) }
    let second = Task { await controller.refreshNavigation(sleep: clock.sleep) }
    await client.snapshots.wait()
    await clock.waitForSleep(.seconds(5), count: 2)
    let operation = try #require(controller.connection(for: "local").manualNavigationRefresh?.task)

    first.cancel()
    await first.value
    #expect(clock.pendingCount == 1)
    #expect(!operation.isCancelled)
    #expect(client.snapshots.value == 1)
    clock.advance(by: .seconds(5))
    await second.value
    #expect(clock.pendingCount == 0)
    release.signal()
    await operation.value
    #expect(controller.navigationSyncStateByMachineId["local"] == .current)
  }

  @Test("Refresh joins an existing preparation and remains bounded")
  func joinsExistingPreparation() async throws {
    let clock = TestClock()
    let release = TestSignal()
    let client = ManualRefreshClient(info: { await release.wait() })
    let controller = try makeController(local: client)
    defer {
      release.signal()
      controller.stopEventSync()
    }
    let preparation = Task { await controller.prepareMachine("local") }
    await client.probes.wait()
    let gesture = Task { await controller.refreshNavigation(sleep: clock.sleep) }
    await clock.waitForSleep(.seconds(5))
    let operation = controller.connection(for: "local").manualNavigationRefresh?.task
    clock.advance(by: .seconds(5))
    await gesture.value
    #expect(client.probes.value == 1)
    #expect(client.snapshots.value == 0)
    release.signal()
    await preparation.value
    await operation?.value
    #expect(client.snapshots.value == 1)
    #expect(controller.navigationSyncStateByMachineId["local"] == .current)
  }

  @Test("A gesture cancelled before starting does not issue requests")
  func cancelledBeforeStarting() async throws {
    let clock = TestClock()
    let client = ManualRefreshClient()
    let controller = try makeController(local: client)
    defer { controller.stopEventSync() }
    let gesture = Task { @MainActor in
      await controller.refreshNavigation(sleep: clock.sleep)
    }
    // Both creation and cancellation run on the main actor before the task
    // can enter refreshNavigation.
    gesture.cancel()
    await gesture.value
    #expect(client.snapshots.value == 0)
    #expect(client.probes.value == 0)
    #expect(clock.pendingCount == 0)
  }

  @Test("An empty fleet returns without starting a deadline")
  func emptyFleetReturnsImmediately() async {
    let clock = TestClock()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel(
        projectRepository: DefaultProjectRepository(store: InMemoryStore()),
        sessionRepository: DefaultSessionRepository(store: InMemoryStore())
      )
    )
    #expect(controller.allMachines.isEmpty)
    await controller.refreshNavigation(sleep: clock.sleep)
    #expect(clock.pendingCount == 0)
  }

  private func makeController(
    local: ManualRefreshClient,
    remote: ManualRefreshClient? = nil
  ) throws -> MachineController {
    let store = InMemoryStore()
    let remotes: [CodevisorMachine] =
      remote == nil
      ? []
      : [
        CodevisorMachine(
          id: "healthy", name: "Healthy", baseURL: URL(string: "http://healthy.test")!, kind: "remote"
        )
      ]
    try store.saveData(JSONEncoder().encode(MachineRegistry(remoteMachines: remotes)), forKey: "machines")
    return MachineController(
      store: store,
      projectList: ProjectListModel(
        projectRepository: DefaultProjectRepository(store: InMemoryStore()),
        sessionRepository: DefaultSessionRepository(store: InMemoryStore())
      ),
      clientFactory: { machine in machine.id == "healthy" ? remote! : local }
    )
  }
}

private final class ManualRefreshClient: CodevisorServerClienting, Sendable {
  let probes = TestSignal()
  let snapshots = TestSignal()
  private let probe: @Sendable () async -> Void
  private let snapshot: @Sendable () async throws -> Void

  init(
    info: @escaping @Sendable () async -> Void = {},
    snapshot: @escaping @Sendable () async throws -> Void = {}
  ) {
    self.probe = info
    self.snapshot = snapshot
  }

  func info() async throws -> ServerInfo {
    probes.signal()
    await probe()
    return ServerInfo(
      id: "local", name: "Local", kind: "local", version: "0.1.0", platform: "darwin", bindHost: "0.0.0.0"
    )
  }

  func listProjects() async throws -> [ServerProject] { [] }
  func listSessions() async throws -> [ServerSession] {
    snapshots.signal()
    try await snapshot()
    return []
  }
  func latestShellEventCursor() async throws -> Int { 0 }
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { _ in }
  }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    ServerUpdateInfo(
      currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false,
      channel: "stable", checkedAt: nil, migrationState: "idle"
    )
  }
  func health() async throws -> ServerHealth { fatalError("unused") }
  func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
  func capabilities(cwd: String) async throws -> ServerCapabilities { fatalError("unused") }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func sessionDetail(id: UUID) async throws -> ServerSessionDetail { fatalError("unused") }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted { fatalError("unused") }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
