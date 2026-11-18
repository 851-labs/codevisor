import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorClient
@testable import CodevisorCore

@MainActor
@Suite struct WorkspaceInspectorHarnessModelTests {
  private typealias Snapshot = WorkspaceInspectorHarnessModel.Snapshot

  private let first = ChatSession(projectId: UUID(), harnessId: "claude")
  private let second = ChatSession(projectId: UUID(), harnessId: "claude")

  @Test func showsNothingUntilBothSourcesSettle() async {
    let model = WorkspaceInspectorHarnessModel()
    let client = HarnessSourcesClient(limits: .weekly(40), context: .used(1_000), isGated: true)
    let load = Task { await model.load(first, client: client, animated: false) }

    client.limitsGate.signal()
    await client.limitsServed.wait()
    #expect(model.snapshot(for: first) == nil)

    client.contextGate.signal()
    await load.value
    #expect(model.snapshot(for: first) == Snapshot(limits: .weekly(40), context: .used(1_000)))
  }

  @Test func prefetchedLimitsShowNothingUntilTheContextSettles() async {
    let model = WorkspaceInspectorHarnessModel()
    let client = HarnessSourcesClient(limits: .weekly(40), context: .used(1_000))
    await model.prefetch([first]) { _ in client }

    #expect(model.snapshot(for: first) == nil)

    await model.load(first, client: client, animated: false)

    #expect(model.snapshot(for: first) == Snapshot(limits: .weekly(40), context: .used(1_000)))
  }

  @Test func showsTheContextWhenTheLimitsFail() async {
    let model = WorkspaceInspectorHarnessModel()

    await model.load(first, client: HarnessSourcesClient(limits: nil, context: .used(1_000)), animated: false)

    #expect(model.snapshot(for: first) == Snapshot(limits: nil, context: .used(1_000)))
  }

  @Test func showsTheLimitsWhenTheContextFails() async {
    let model = WorkspaceInspectorHarnessModel()

    await model.load(first, client: HarnessSourcesClient(limits: .weekly(40), context: nil), animated: false)

    #expect(model.snapshot(for: first) == Snapshot(limits: .weekly(40), context: nil))
  }

  @Test func refreshKeepsTheShownDataUntilTheNewDataArrives() async {
    let model = WorkspaceInspectorHarnessModel()
    await model.load(first, client: HarnessSourcesClient(limits: .weekly(40), context: .used(1_000)), animated: false)
    let client = HarnessSourcesClient(limits: .weekly(55), context: .used(2_000), isGated: true)
    let refresh = Task { await model.load(first, client: client, animated: true) }

    client.limitsGate.signal()
    await client.limitsServed.wait()
    #expect(model.snapshot(for: first) == Snapshot(limits: .weekly(40), context: .used(1_000)))

    client.contextGate.signal()
    await refresh.value
    #expect(model.snapshot(for: first) == Snapshot(limits: .weekly(55), context: .used(2_000)))
  }

  @Test func failedRefreshKeepsTheShownData() async {
    let model = WorkspaceInspectorHarnessModel()
    await model.load(first, client: HarnessSourcesClient(limits: .weekly(40), context: .used(1_000)), animated: false)

    await model.load(first, client: HarnessSourcesClient(limits: nil, context: nil), animated: true)

    #expect(model.snapshot(for: first) == Snapshot(limits: .weekly(40), context: .used(1_000)))
  }

  @Test func switchingToAnUnloadedChatShowsNothingUntilItSettles() async {
    let model = WorkspaceInspectorHarnessModel()
    await model.load(first, client: HarnessSourcesClient(limits: .weekly(40), context: .used(1_000)), animated: false)

    #expect(model.snapshot(for: second) == nil)

    await model.load(second, client: HarnessSourcesClient(limits: .weekly(40), context: .used(3_000)), animated: false)

    #expect(model.snapshot(for: second) == Snapshot(limits: .weekly(40), context: .used(3_000)))
    #expect(model.snapshot(for: first) == Snapshot(limits: .weekly(40), context: .used(1_000)))
  }
}

extension ServerHarnessUsageLimits {
  fileprivate static func weekly(_ usedPercent: Double) -> Self {
    ServerHarnessUsageLimits(
      state: "available", harnessId: "claude", accountId: nil, accountLabel: nil, accountEmail: nil, plan: nil,
      windows: [
        .init(id: "weekly", label: "Weekly limit", usedPercent: usedPercent, durationMinutes: nil, resetsAt: nil)
      ],
      credits: nil, detail: nil, fetchedAt: "2026-11-18T00:00:00Z")
  }
}

extension ServerSessionContext {
  fileprivate static func used(_ tokens: Double) -> Self {
    ServerSessionContext(
      model: nil, totalTokens: tokens, maxTokens: 1_000_000,
      categories: [.init(name: "Messages", tokens: tokens, color: nil, isDeferred: nil)])
  }
}

private final class HarnessSourcesClient: CodevisorServerClienting, @unchecked Sendable {
  let limits: ServerHarnessUsageLimits?
  let context: ServerSessionContext?
  let limitsGate = TestSignal()
  let contextGate = TestSignal()
  let limitsServed = TestSignal()

  init(limits: ServerHarnessUsageLimits?, context: ServerSessionContext?, isGated: Bool = false) {
    self.limits = limits
    self.context = context
    guard !isGated else { return }
    limitsGate.signal()
    contextGate.signal()
  }

  func sessionUsageLimits(id: UUID) async throws -> ServerHarnessUsageLimits {
    await limitsGate.wait()
    defer { limitsServed.signal() }
    guard let limits else { throw CodevisorServerClientError.invalidResponse }
    return limits
  }

  func sessionContext(id: UUID) async throws -> ServerSessionContext? {
    await contextGate.wait()
    guard let context else { throw CodevisorServerClientError.invalidResponse }
    return context
  }

  func info() async throws -> ServerInfo {
    ServerInfo(id: "local", name: "Local", kind: "local", version: "0.1.0", platform: "darwin", bindHost: "0.0.0.0")
  }
  func health() async throws -> ServerHealth {
    ServerHealth(ok: true, version: "0.1.0", database: "ready", bootId: nil)
  }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    ServerUpdateInfo(
      currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false,
      channel: "stable", checkedAt: nil, migrationState: "idle")
  }
  func listProjects() async throws -> [ServerProject] { [] }
  func listSessions() async throws -> [ServerSession] { [] }
  func latestShellEventCursor() async throws -> Int { 0 }
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { _ in }
  }
  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted { fatalError("unused") }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
