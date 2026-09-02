import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

/// A failed remote preparation must not park the machine forever: one relay
/// timeout used to latch the request gate `.failed` (every later request
/// failed instantly, offline) with nothing scheduled to retry.
@MainActor
struct MachinePreparationRetryTests {
  @Test("A failed remote preparation retries automatically and recovers")
  func failedPreparationRetriesAutomatically() async throws {
    let fake = PreparationFakeServerClient()
    fake.setInfoFails(true)
    let controller = makeController(fake: fake)
    let remote = try controller.addRemote(host: "10.0.0.9", select: false)

    await controller.prepareMachine(remote.id)
    guard case .failed = controller.availabilityByMachineId[remote.id] else {
      Issue.record("A failed preparation should surface as failed availability")
      return
    }
    // Latched: the gate fails instantly without touching the network.
    await #expect(throws: ServerRequestGateError.self) {
      try await controller.requestGate.waitUntilReady(for: remote.id)
    }

    // The machine comes back; the scheduled retry recovers on its own —
    // no foreground event, no user retry.
    fake.setInfoFails(false)
    try await waitUntil {
      controller.availabilityByMachineId[remote.id] == .ready
    }
    try await waitUntil {
      controller.navigationSyncStateByMachineId[remote.id] == .current
    }
    // And the latch is gone: requests flow again.
    try await controller.requestGate.waitUntilReady(for: remote.id)
  }

  @Test("A user-driven re-preparation clears the latch immediately")
  func explicitRetryClearsLatch() async throws {
    let fake = PreparationFakeServerClient()
    fake.setInfoFails(true)
    let controller = makeController(fake: fake)
    let remote = try controller.addRemote(host: "10.0.0.9", select: false)

    await controller.prepareMachine(remote.id)
    await #expect(throws: ServerRequestGateError.self) {
      try await controller.requestGate.waitUntilReady(for: remote.id)
    }

    // The user retries (Home's alert / pull-to-refresh both route here):
    // a full preparation, which re-arms and then clears the gate.
    fake.setInfoFails(false)
    await controller.retryMachine(remote.id)
    try await controller.requestGate.waitUntilReady(for: remote.id)
    try await waitUntil {
      controller.navigationSyncStateByMachineId[remote.id] == .current
    }
  }

  private func makeController(fake: PreparationFakeServerClient) -> MachineController {
    let projectList = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    return MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { _ in fake },
      preparationRetryBaseDelay: .milliseconds(10)
    )
  }
}

private final class PreparationFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  private struct InfoFailure: Error {}

  private let lock = NSLock()
  private var infoFails = false

  func setInfoFails(_ fails: Bool) {
    lock.withLock { infoFails = fails }
  }

  func info() async throws -> ServerInfo {
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
  func listSessions() async throws -> [ServerSession] { [] }
  func latestShellEventCursor() async throws -> Int { 0 }

  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { _ in }
  }

  func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
  func capabilities(cwd: String) async throws -> ServerCapabilities {
    ServerCapabilities(harnesses: [])
  }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness {
    fatalError("unused")
  }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func sessionDetail(id: UUID) async throws -> ServerSessionDetail { fatalError("unused") }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    fatalError("unused")
  }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
