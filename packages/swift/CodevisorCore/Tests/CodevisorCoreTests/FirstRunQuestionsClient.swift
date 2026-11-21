import ACPKit
import CodevisorClient
import CodevisorTestSupport
import Foundation
import Synchronization

@testable import CodevisorCore

final class FirstRunQuestionsClient: CodevisorServerClienting, @unchecked Sendable {
  struct Answer: Equatable {
    let id: String
    let access: ServerFirstRunFolderAnswer.Access
  }

  let answered = TestSignal()
  private let refusesAnswers: Bool
  private let state: Mutex<State>
  private let events = AsyncThrowingStream<ServerEventEnvelope, any Error>.makeStream()

  private struct State {
    var status: ServerFirstRunStatus
    var answers: [Answer] = []
    var claudeCodeLoginAnswers: [ServerFirstRunClaudeCodeLoginAnswer.Choice] = []
    var published = 0
  }

  init(status: ServerFirstRunStatus, refusesAnswers: Bool = false) {
    self.refusesAnswers = refusesAnswers
    state = Mutex(State(status: status))
  }

  convenience init(asking: [ServerFirstRunFolder], refusesAnswers: Bool = false) {
    self.init(status: ServerFirstRunStatus(state: .done, folders: asking), refusesAnswers: refusesAnswers)
  }

  var answers: [Answer] { state.withLock { $0.answers } }

  var claudeCodeLoginAnswers: [ServerFirstRunClaudeCodeLoginAnswer.Choice] {
    state.withLock { $0.claudeCodeLoginAnswers }
  }

  func publish(asking: [ServerFirstRunFolder]) {
    publish(ServerFirstRunStatus(state: .done, folders: asking.isEmpty ? nil : asking))
  }

  func publish(_ next: ServerFirstRunStatus) {
    let (status, id) = state.withLock { state in
      state.status = next
      state.published += 1
      return (state.status, state.published)
    }
    events.continuation.yield(Self.envelope(id: id, status: status))
  }

  func waitUntilConnected() async -> Bool { true }

  func firstRunStatus() async throws -> ServerFirstRunStatus {
    state.withLock { $0.status }
  }

  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    events.stream
  }

  func answerFirstRunFolder(
    id: String, access: ServerFirstRunFolderAnswer.Access
  ) async throws -> ServerFirstRunStatus {
    if refusesAnswers { throw CodevisorServerClientError.invalidResponse }
    let status = state.withLock { state in
      state.answers.append(Answer(id: id, access: access))
      return state.status
    }
    answered.signal()
    return status
  }

  func answerFirstRunClaudeCodeLogin(
    _ choice: ServerFirstRunClaudeCodeLoginAnswer.Choice
  ) async throws -> ServerFirstRunStatus {
    if refusesAnswers { throw CodevisorServerClientError.httpStatus(409, #"{"error":"Couldn't move it"}"#) }
    let status = state.withLock { state in
      state.claudeCodeLoginAnswers.append(choice)
      return state.status
    }
    answered.signal()
    return status
  }

  func info() async throws -> ServerInfo {
    ServerInfo(id: "local", name: "Local", kind: "local", version: "0.1.0", platform: "darwin", bindHost: "0.0.0.0")
  }
  func health() async throws -> ServerHealth {
    ServerHealth(ok: true, version: "0.1.0", database: "ready")
  }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    ServerUpdateInfo(
      currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false,
      channel: "stable", checkedAt: nil, migrationState: "idle")
  }
  func listProjects() async throws -> [ServerProject] { [] }
  func listSessions() async throws -> [ServerSession] { [] }
  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted { fatalError("unused") }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}

  private static func envelope(id: Int, status: ServerFirstRunStatus) -> ServerEventEnvelope {
    let payload = try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(status))
    return ServerEventEnvelope(
      id: id,
      serverId: "local",
      kind: ServerFirstRunStatus.eventKind,
      subjectId: ServerFirstRunStatus.eventSubject,
      createdAt: "2026-11-13T00:00:00Z",
      payload: payload
    )
  }
}
