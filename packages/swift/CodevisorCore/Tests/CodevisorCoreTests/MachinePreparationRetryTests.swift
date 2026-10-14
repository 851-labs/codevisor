import ACPKit
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
struct MachinePreparationRetryTests {
  @Test("A failed remote preparation retries automatically and recovers")
  func failedPreparationRetriesAutomatically() async throws {
    let fake = PreparationFakeServerClient()
    fake.setInfoFails(true)
    let clock = TestClock()
    let controller = makeController(fake: fake, clock: clock)
    defer { controller.stopEventSync() }
    let remote = accountMachine("remote-box")
    signIn(controller, machines: [remote])

    await controller.prepareMachine(remote.id)
    guard case .failed = controller.availabilityByMachineId[remote.id] else {
      Issue.record("A failed preparation should surface as failed availability")
      return
    }
    let failure = try #require(controller.navigationSyncStateByMachineId[remote.id])
    guard case .stale = failure else {
      Issue.record("A failed preparation should keep its connection warning visible")
      return
    }
    await #expect(throws: ServerRequestGateError.self) {
      try await controller.requestGate.waitUntilReady(for: remote.id)
    }

    let probeStarted = TestSignal()
    let probeGate = TestSignal()
    fake.setInfoDelay {
      probeStarted.signal()
      await probeGate.wait()
    }
    let snapshotStarted = TestSignal()
    let snapshotGate = TestSignal()
    fake.setSnapshotDelay {
      snapshotStarted.signal()
      await snapshotGate.wait()
    }
    fake.setInfoFails(false)
    await clock.waitForSleep(.seconds(2))
    #expect(controller.navigationSyncStateByMachineId[remote.id] == failure)
    clock.advance(by: .seconds(2))
    await probeStarted.wait()
    #expect(controller.availabilityByMachineId[remote.id] == .waiting(.connecting))
    #expect(controller.navigationSyncStateByMachineId[remote.id] == failure)
    probeGate.signal()

    await snapshotStarted.wait()
    #expect(controller.availabilityByMachineId[remote.id] == .ready)
    #expect(controller.navigationSyncStateByMachineId[remote.id] == failure)
    snapshotGate.signal()
    try await waitUntil {
      controller.navigationSyncStateByMachineId[remote.id] == .current
    }
    await controller.connection(for: remote.id).preparationTask?.value
    try await controller.requestGate.waitUntilReady(for: remote.id)
  }

  @Test("A user-driven re-preparation clears the latch immediately")
  func explicitRetryClearsLatch() async throws {
    let fake = PreparationFakeServerClient()
    fake.setInfoFails(true)
    let clock = TestClock()
    let controller = makeController(fake: fake, clock: clock)
    let remote = accountMachine("remote-box")
    signIn(controller, machines: [remote])

    await controller.prepareMachine(remote.id)
    await #expect(throws: ServerRequestGateError.self) {
      try await controller.requestGate.waitUntilReady(for: remote.id)
    }

    fake.setInfoFails(false)
    await controller.retryMachine(remote.id)
    try await controller.requestGate.waitUntilReady(for: remote.id)
    try await waitUntil {
      controller.navigationSyncStateByMachineId[remote.id] == .current
    }
  }

  @Test("A local server that won't start is retried on the same backoff, never given up on")
  func failedLocalServerRetries() async throws {
    let fake = PreparationFakeServerClient()
    let clock = TestClock()
    let local = StubLocalServer()
    local.state = .unavailable("The server didn't start")
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      localServer: local,
      clientFactory: { _ in fake },
      preparationSleep: clock.sleep
    )
    defer { controller.stopEventSync() }

    await controller.prepareMachine("local")
    guard case .failed = controller.availabilityByMachineId["local"] else {
      Issue.record("A local server that won't start should surface as failed availability")
      return
    }

    local.state = .started
    await clock.waitForSleep(.seconds(2))
    clock.advance(by: .seconds(2))
    try await waitUntil { controller.availabilityByMachineId["local"] == .ready }
  }

  private func makeController(fake: PreparationFakeServerClient, clock: TestClock) -> MachineController {
    let projectList = ProjectListModel.fixture()
    return MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { _ in fake },
      preparationSleep: clock.sleep
    )
  }
}

private final class PreparationFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  private struct InfoFailure: Error {}

  private let lock = NSLock()
  private var infoFails = false
  private var infoDelay: (@Sendable () async -> Void)?
  private var snapshotDelay: (@Sendable () async -> Void)?

  func setInfoDelay(_ delay: @escaping @Sendable () async -> Void) {
    lock.withLock { infoDelay = delay }
  }

  func setSnapshotDelay(_ delay: @escaping @Sendable () async -> Void) {
    lock.withLock { snapshotDelay = delay }
  }

  func setInfoFails(_ fails: Bool) {
    lock.withLock { infoFails = fails }
  }

  func info() async throws -> ServerInfo {
    if let delay = lock.withLock({ infoDelay }) { await delay() }
    if lock.withLock({ infoFails }) { throw InfoFailure() }
    return ServerInfo(
      id: "remote", name: "Remote", kind: "remote", version: "0.1.0",
      platform: "darwin", bindHost: "0.0.0.0"
    )
  }

  func health() async throws -> ServerHealth {
    ServerHealth(ok: true, version: "0.1.0", database: "ready", bootId: nil)
  }

  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    ServerUpdateInfo(
      currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false,
      channel: "stable", checkedAt: nil, migrationState: "idle"
    )
  }

  func listProjects() async throws -> [ServerProject] { [] }
  func listSessions() async throws -> [ServerSession] {
    if let delay = lock.withLock({ snapshotDelay }) { await delay() }
    return []
  }
  func latestShellEventCursor() async throws -> Int { 0 }

  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { _ in }
  }

  func capabilities(cwd: String) async throws -> ServerCapabilities {
    ServerCapabilities(harnesses: [])
  }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    fatalError("unused")
  }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
