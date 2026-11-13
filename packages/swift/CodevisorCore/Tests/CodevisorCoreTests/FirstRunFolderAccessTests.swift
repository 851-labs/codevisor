import ACPKit
import CodevisorClient
import CodevisorTestSupport
import Foundation
import Synchronization
import Testing

@testable import CodevisorCore

@MainActor
@Suite("First-run folder questions")
struct FirstRunFolderAccessTests {
  private static let documents = ServerFirstRunFolder(
    id: "documents", name: "Documents", path: "/Users/me/Documents", projects: ["api"])
  private static let desktop = ServerFirstRunFolder(
    id: "desktop", name: "Desktop", path: "/Users/me/Desktop", projects: ["site"])
  private static let downloads = ServerFirstRunFolder(
    id: "downloads", name: "Downloads", path: "/Users/me/Downloads", projects: ["demo"])

  @Test("Asks only about folders macOS hasn't decided, and answers the rest by itself")
  func asksAboutUndecidedFolders() async {
    let client = FolderQuestionsClient(asking: [Self.documents, Self.desktop, Self.downloads])
    let access = FirstRunFolderAccess(client: client) { folder in
      ["desktop": .allowed, "downloads": .denied][folder.id] ?? .undetermined
    }
    let following = Task { await access.follow() }

    await client.answered.wait(for: 2)
    #expect(access.asking == [Self.documents])
    #expect(client.answers == [.init(id: "desktop", access: .allow), .init(id: "downloads", access: .decline)])

    client.publish(asking: [])
    await following.value
    #expect(!access.isAsking)
  }

  @Test("Keeps a folder up while the server works on its answer, then moves to the next")
  func movesToTheNextFolder() async {
    let client = FolderQuestionsClient(asking: [Self.documents, Self.desktop])
    let access = FirstRunFolderAccess(client: client) { _ in .undetermined }
    let following = Task { await access.follow() }
    await awaitObserved { access.asking.count == 2 }

    await access.answer(Self.documents, allow: true)
    #expect(access.current == Self.documents)
    #expect(access.answeringId == "documents")
    #expect(client.answers == [.init(id: "documents", access: .allow)])

    client.publish(asking: [Self.desktop])
    await awaitObserved { access.current == Self.desktop }
    #expect(access.answeringId == nil)
    #expect(access.answered == 1)

    client.publish(asking: [])
    await following.value
  }

  @Test("Drops a folder whose answer can't be sent, so the sheet never traps the user")
  func dropsAFolderItCannotAnswer() async {
    let client = FolderQuestionsClient(asking: [Self.documents], refusesAnswers: true)
    let access = FirstRunFolderAccess(client: client) { _ in .undetermined }
    let following = Task { await access.follow() }
    await awaitObserved { access.isAsking }

    await access.answer(Self.documents, allow: true)
    #expect(!access.isAsking)
    #expect(access.answeringId == nil)

    client.publish(asking: [])
    await following.value
  }
}

private final class FolderQuestionsClient: CodevisorServerClienting, @unchecked Sendable {
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
    var published = 0
  }

  init(asking: [ServerFirstRunFolder], refusesAnswers: Bool = false) {
    self.refusesAnswers = refusesAnswers
    state = Mutex(State(status: ServerFirstRunStatus(state: .done, folders: asking)))
  }

  var answers: [Answer] { state.withLock { $0.answers } }

  func publish(asking: [ServerFirstRunFolder]) {
    let (status, id) = state.withLock { state in
      state.status = ServerFirstRunStatus(state: .done, folders: asking.isEmpty ? nil : asking)
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
