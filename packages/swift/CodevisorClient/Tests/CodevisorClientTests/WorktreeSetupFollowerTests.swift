import ACPKit
import CodevisorProtocol
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorClient

@Suite("WorktreeSetupFollower")
struct WorktreeSetupFollowerTests {
  @Test("A slow checkout finishes when the machine announces the worktree, with no deadline")
  func waitsForCreatedEvent() async throws {
    let client = SetupScriptClient(start: .success(.running("wt-1")))
    let clock = TestClock()
    let follower = Self.follower(client, clock: clock)

    let run = Task { try await follower.run() }
    let events = await client.subscription()
    await clock.waitForSleep(WorktreeSetupFollower.recheckInterval)
    events.yield(Self.created(Self.worktree("wt-1", name: "lager")))

    #expect(try await run.value.name == "lager")
  }

  @Test("A failed checkout surfaces git's reason from the setup event")
  func failsWithEventMessage() async throws {
    let client = SetupScriptClient(start: .success(.running("wt-1")))
    let follower = Self.follower(client, clock: TestClock())

    let run = Task { try await follower.run() }
    await client.subscription().yield(Self.setupFailed("wt-1", "fatal: 'lager' already exists"))

    await #expect(throws: WorktreeSetupFailure(message: "fatal: 'lager' already exists")) {
      try await run.value
    }
  }

  @Test("A missed event is caught by the next status check")
  func recheckFindsCompletion() async throws {
    let client = SetupScriptClient(start: .success(.running("wt-1")))
    let clock = TestClock()
    let follower = Self.follower(client, clock: clock)

    let run = Task { try await follower.run() }
    await clock.waitForSleep(WorktreeSetupFollower.recheckInterval)
    client.setStatus(.success(.completed(Self.worktree("wt-1", name: "lager"))))
    clock.advance(by: WorktreeSetupFollower.recheckInterval)

    #expect(try await run.value.name == "lager")
  }

  @Test("Losing the machine keeps waiting, and the next check after it returns picks the result up")
  func connectionLossKeepsWaiting() async throws {
    let client = SetupScriptClient(start: .success(.running("wt-1")))
    client.setStatus(.failure(URLError(.networkConnectionLost)))
    let clock = TestClock()
    let follower = Self.follower(client, clock: clock)

    let run = Task { try await follower.run() }
    await clock.waitForSleep(WorktreeSetupFollower.recheckInterval)
    clock.advance(by: WorktreeSetupFollower.recheckInterval)
    await client.statusChecked.wait(for: 1)
    await clock.waitForSleep(WorktreeSetupFollower.recheckInterval, count: 2)
    client.setStatus(.success(.completed(Self.worktree("wt-1", name: "lager"))))
    clock.advance(by: WorktreeSetupFollower.recheckInterval)

    #expect(try await run.value.name == "lager")
  }

  @Test("A start the machine never saw is sent again with the same id")
  func restartsUnknownSetup() async throws {
    let client = SetupScriptClient(start: .failure(URLError(.networkConnectionLost)))
    client.setStatus(.failure(CodevisorServerClientError.httpStatus(404, #"{"error":"No worktree setup"}"#)))
    let clock = TestClock()
    let follower = Self.follower(client, clock: clock)

    let run = Task { try await follower.run() }
    await clock.waitForSleep(WorktreeSetupFollower.recheckInterval)
    client.setStart(.success(.completed(Self.worktree("wt-1", name: "lager"))))
    clock.advance(by: WorktreeSetupFollower.recheckInterval)

    #expect(try await run.value.name == "lager")
    #expect(client.startedIds == ["wt-1", "wt-1"])
  }

  @Test("A machine without setup jobs creates the worktree in one request")
  func olderMachineFallsBack() async throws {
    let client = SetupScriptClient(start: .failure(CodevisorServerClientError.httpStatus(404, "Route not found")))
    client.setCreated(Self.worktree("wt-1", name: "lager"))

    let worktree = try await Self.follower(client, clock: TestClock()).run()

    #expect(worktree.name == "lager")
  }

  private static func follower(_ client: SetupScriptClient, clock: TestClock) -> WorktreeSetupFollower {
    WorktreeSetupFollower(client: client, projectId: UUID(), worktreeId: "wt-1", clock: clock)
  }

  private static func worktree(_ id: String, name: String) -> ServerWorktree {
    try! JSONDecoder().decode(ServerWorktree.self, from: JSONEncoder().encode(worktreeJSON(id, name: name)))
  }

  private static func worktreeJSON(_ id: String, name: String) -> JSONValue {
    .object([
      "id": .string(id), "projectId": .string("project"), "serverId": .string("local"), "name": .string(name),
      "branch": .string("codevisor/\(name)"), "path": .string("/wt/\(name)"), "createdAt": .string(""),
    ])
  }

  private static func created(_ worktree: ServerWorktree) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: 2, serverId: "local", kind: "worktree.created", subjectId: worktree.id, createdAt: "",
      payload: worktreeJSON(worktree.id, name: worktree.name))
  }

  private static func setupFailed(_ worktreeId: String, _ message: String) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: 3, serverId: "local", kind: "worktree.setup", subjectId: worktreeId, createdAt: "",
      payload: .object(["state": .string("failed"), "message": .string(message)]))
  }
}

private final class SetupScriptClient: CodevisorServerClienting, @unchecked Sendable {
  private let lock = NSLock()
  private var start: Result<ServerWorktreeSetupStatus, any Error>
  private var status: Result<ServerWorktreeSetupStatus, any Error> = .success(.running("wt-1"))
  private var created: ServerWorktree?
  private var started: [String] = []
  private var streams: [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation] = []
  private let subscribed = TestSignal()
  let statusChecked = TestSignal()

  init(start: Result<ServerWorktreeSetupStatus, any Error>) {
    self.start = start
  }

  var startedIds: [String] { lock.withLock { started } }

  func setStart(_ result: Result<ServerWorktreeSetupStatus, any Error>) { lock.withLock { start = result } }
  func setStatus(_ result: Result<ServerWorktreeSetupStatus, any Error>) { lock.withLock { status = result } }
  func setCreated(_ worktree: ServerWorktree) { lock.withLock { created = worktree } }

  func subscription() async -> AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation {
    await subscribed.wait(for: 1)
    return lock.withLock { streams[0] }
  }

  func startWorktreeSetup(projectId: UUID, id: String, name: String?) async throws -> ServerWorktreeSetupStatus {
    try lock.withLock {
      started.append(id)
      return try start.get()
    }
  }

  func worktreeSetupStatus(projectId: UUID, worktreeId: String) async throws -> ServerWorktreeSetupStatus {
    defer { statusChecked.signal() }
    return try lock.withLock { try status.get() }
  }

  func createWorktree(projectId: UUID, id: String?, name: String?) async throws -> ServerWorktree {
    guard let worktree = lock.withLock({ created }) else { throw CodevisorServerClientError.invalidResponse }
    return worktree
  }

  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: ServerEventEnvelope.self, throwing: (any Error).self)
    lock.withLock { streams.append(continuation) }
    subscribed.signal()
    return stream
  }

  func health() async throws -> ServerHealth {
    ServerHealth(ok: true, version: "0.1.0", database: "ready", bootId: nil)
  }
  func info() async throws -> ServerInfo {
    ServerInfo(id: "local", name: "Local", kind: "local", version: "0.1.0", platform: "darwin", bindHost: "127.0.0.1")
  }
  func rescanHarnesses() async throws -> [ServerHarness] { [] }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    ServerUpdateInfo(
      currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false, channel: "stable", checkedAt: nil,
      migrationState: "idle")
  }
  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
  func listProjects() async throws -> [ServerProject] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func listSessions() async throws -> [ServerSession] { [] }
  func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
  }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
  func requestShutdown() async throws {}
}
