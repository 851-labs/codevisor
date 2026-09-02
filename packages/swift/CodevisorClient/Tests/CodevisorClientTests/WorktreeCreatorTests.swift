import Foundation
import Testing
import CodevisorProtocol

@testable import CodevisorClient

@MainActor
@Suite("WorktreeCreator")
struct WorktreeCreatorTests {
  @Test("A successful creation returns the worktree and succeeds the phase")
  func success() async throws {
    let client = WorktreeStubClient(result: .success(Self.worktree(name: "kiwi")))
    let creator = WorktreeCreator()

    let result = await creator.create(projectId: UUID(), client: client)

    let worktree = try result.get()
    #expect(worktree.name == "kiwi")
    #expect(creator.phase?.outcome == .succeeded)
    #expect(!creator.isRunning)
    // The client-generated worktree id rode the request.
    #expect(client.receivedId?.isEmpty == false)
  }

  @Test("An HTTP failure surfaces the server's error message and fails the phase")
  func httpFailure() async {
    let client = WorktreeStubClient(
      result: .failure(
        CodevisorServerClientError.httpStatus(422, #"{"error":"Not a git repository."}"#)
      ))
    let creator = WorktreeCreator()

    let result = await creator.create(projectId: UUID(), client: client)

    guard case let .failure(failure) = result else {
      Issue.record("expected failure")
      return
    }
    #expect(failure.message == "Not a git repository.")
    #expect(creator.phase?.failureMessage == "Not a git repository.")
    #expect(!creator.isRunning)
  }

  @Test("A missing client fails fast without a phase mutation cycle")
  func missingClient() async {
    let creator = WorktreeCreator()
    let result = await creator.create(projectId: UUID(), client: nil)
    guard case .failure = result else {
      Issue.record("expected failure")
      return
    }
  }

  @Test("reset clears a failed phase so the picker can return")
  func resetClearsPhase() async {
    let client = WorktreeStubClient(
      result: .failure(
        CodevisorServerClientError.httpStatus(500, "")
      ))
    let creator = WorktreeCreator()
    _ = await creator.create(projectId: UUID(), client: client)
    #expect(creator.phase != nil)

    creator.reset()

    #expect(creator.phase == nil)
  }

  @Test("Failure messages parse the server's error body")
  func failureMessages() {
    #expect(WorktreeCreator.failureMessage(from: #"{"error":"Nope"}"#) == "Nope")
    #expect(WorktreeCreator.failureMessage(from: "plain text") == "plain text")
    #expect(WorktreeCreator.failureMessage(from: "") == "Could not create the worktree.")
  }

  private static func worktree(name: String) -> ServerWorktree {
    try! JSONDecoder().decode(
      ServerWorktree.self,
      from: Data(
        """
        {"id":"\(UUID().uuidString.lowercased())","projectId":"\(UUID().uuidString)",
        "serverId":"local","name":"\(name)","branch":"codevisor/\(name)",
        "path":"/wt/\(name)","createdAt":"2026-01-01T00:00:00Z"}
        """.utf8))
  }
}

/// Minimal client stub: `createWorktree` is scripted; everything else uses
/// the protocol's fake-friendly defaults or inert stubs.
private final class WorktreeStubClient: CodevisorServerClienting, @unchecked Sendable {
  private let result: Result<ServerWorktree, any Error>
  private let lock = NSLock()
  private var _receivedId: String?

  init(result: Result<ServerWorktree, any Error>) {
    self.result = result
  }

  var receivedId: String? { lock.withLock { _receivedId } }

  func createWorktree(projectId: UUID, id: String?, name: String?) async throws -> ServerWorktree {
    lock.withLock { _receivedId = id }
    return try result.get()
  }

  func health() async throws -> ServerHealth {
    ServerHealth(ok: true, version: "0.1.0", database: "ready", bootId: nil)
  }
  func info() async throws -> ServerInfo {
    ServerInfo(
      id: "local", name: "Local", kind: "local", version: "0.1.0",
      platform: "darwin", bindHost: "127.0.0.1"
    )
  }
  func rescanHarnesses() async throws -> [ServerHarness] { [] }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    ServerUpdateInfo(
      currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false,
      channel: "stable", checkedAt: nil, migrationState: "idle"
    )
  }
  func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
  func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
  func listProjects() async throws -> [ServerProject] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func listSessions() async throws -> [ServerSession] { [] }
  func sessionDetail(id: UUID) async throws -> ServerSessionDetail { fatalError("unused") }
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
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { continuation in continuation.finish() }
  }
}
