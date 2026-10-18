import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("BotConversationModel", .timeLimit(.minutes(1)))
struct BotConversationModelTests {
  private let sessionId = UUID(uuidString: "6F4B8E1C-8C1E-4D8F-9A51-2E6B0D7C9A10")!

  private func message(
    _ id: String, _ sequence: Int, _ sender: ServerBotMessageSender = .bot,
    at createdAt: String = "2026-10-18T12:00:00.000Z"
  ) -> ServerBotMessage {
    ServerBotMessage(
      id: id, sessionId: sessionId.uuidString.lowercased(), sequence: sequence, sender: sender,
      text: id, createdAt: createdAt)
  }

  private func event(_ kind: String, _ payload: JSONValue) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: 1, serverId: "local", kind: kind, subjectId: sessionId.uuidString, createdAt: "", payload: payload)
  }

  private func messageEvent(_ message: ServerBotMessage) throws -> ServerEventEnvelope {
    let data = try JSONEncoder().encode(message)
    return event("bot.message", .object(["message": try JSONDecoder().decode(JSONValue.self, from: data)]))
  }

  @Test("A sent message stays at the end until the server echo replaces it in place")
  func optimisticSendIsReplacedByEcho() async throws {
    let client = BotConversationFakeClient()
    client.pages = [ServerBotConversationPage(messages: [message("hello", 1)], hasMore: false, working: false)]
    let model = BotConversationModel(
      sessionId: sessionId, client: client, now: { Date(timeIntervalSince1970: 1_792_324_800) })
    await model.refreshLatest()

    await model.send("  ship it  ")
    let sent = try #require(client.prompts.first)
    #expect(sent.text == "ship it")
    #expect(model.pending.map(\.id) == [sent.messageId])
    #expect(model.isWorking)

    try await model.apply(
      messageEvent(
        ServerBotMessage(
          id: sent.messageId, sessionId: sessionId.uuidString.lowercased(), sequence: 2, sender: .user,
          text: "ship it", createdAt: "2026-10-18T12:00:01.000Z")))
    try await model.apply(messageEvent(message("on it", 3)))

    #expect(model.pending.isEmpty)
    #expect(model.messages.map(\.sequence) == [1, 2, 3])
  }

  @Test("A failed send is kept as failed and can be retried")
  func failedSendRetries() async throws {
    let client = BotConversationFakeClient()
    client.failPrompts = true
    let model = BotConversationModel(sessionId: sessionId, client: client)

    await model.send("hi")
    let id = try #require(model.pending.first?.id)
    #expect(model.failedIds == [id])

    client.failPrompts = false
    await model.retry(id)
    #expect(model.failedIds.isEmpty)
    #expect(client.prompts.map(\.messageId) == [id])
  }

  @Test("Turn lifecycle events drive the working indicator")
  func workingFollowsTurns() async {
    let model = BotConversationModel(sessionId: sessionId, client: BotConversationFakeClient())
    await model.apply(event("session.updated", .object(["turnState": .string("started")])))
    #expect(model.isWorking)
    await model.apply(event("session.updated", .object(["turnState": .string("ended")])))
    #expect(!model.isWorking)
    await model.apply(event("session.updated", .object(["turnState": .string("started")])))
    await model.apply(event("session.error", .object(["message": .string("rate limited")])))
    #expect(!model.isWorking)
  }

  @Test("Reconnecting with a gap replaces history instead of leaving a hole")
  func reconnectGapReplacesHistory() async {
    let client = BotConversationFakeClient()
    client.pages = [
      ServerBotConversationPage(messages: [message("a", 1), message("b", 2)], hasMore: false, working: false),
      ServerBotConversationPage(messages: [message("y", 90), message("z", 91)], hasMore: true, working: true),
    ]
    let model = BotConversationModel(sessionId: sessionId, client: client)
    await model.refreshLatest()
    await model.apply(event("client.synchronization", .object(["state": .string("caughtUp")])))

    #expect(model.messages.map(\.id) == ["y", "z"])
    #expect(model.hasMore)
    #expect(model.isWorking)
  }
}

@Suite("BotConversationLayout")
struct BotConversationLayoutTests {
  private func message(
    _ id: String, _ sender: ServerBotMessageSender, _ createdAt: String
  ) -> (
    message: ServerBotMessage, delivery: BotMessageDelivery
  ) {
    (ServerBotMessage(id: id, sessionId: "s", sequence: 0, sender: sender, text: id, createdAt: createdAt), .delivered)
  }

  @Test("Consecutive messages group by sender, notices stand alone, and long gaps get a timestamp")
  func groupsAndTimestamps() {
    let rows = BotConversationLayout.rows([
      message("u1", .user, "2026-10-18T12:00:00.000Z"),
      message("u2", .user, "2026-10-18T12:00:30.000Z"),
      message("b1", .bot, "2026-10-18T12:01:00.000Z"),
      message("n1", .notice, "2026-10-18T12:01:10.000Z"),
      message("b2", .bot, "2026-10-18T12:01:20.000Z"),
      message("b3", .bot, "2026-10-18T12:30:00.000Z"),
    ])

    let shape = rows.map { row -> String in
      switch row {
      case .timestamp: "time"
      case let .message(entry): "\(entry.id)\(entry.startsGroup ? "^" : "")\(entry.endsGroup ? "$" : "")"
      case let .notice(entry): "notice:\(entry.id)"
      }
    }
    #expect(shape == ["time", "u1^", "u2$", "b1^$", "notice:n1", "b2^$", "time", "b3^$"])
  }
}

final class BotConversationFakeClient: CodevisorServerClienting, @unchecked Sendable {
  struct Prompt: Equatable {
    let text: String
    let messageId: String
  }

  private let lock = NSLock()
  private var _pages: [ServerBotConversationPage] = []
  private var _prompts: [Prompt] = []
  private var _failPrompts = false

  var pages: [ServerBotConversationPage] {
    get { lock.withLock { _pages } }
    set { lock.withLock { _pages = newValue } }
  }
  var prompts: [Prompt] { lock.withLock { _prompts } }
  var failPrompts: Bool {
    get { lock.withLock { _failPrompts } }
    set { lock.withLock { _failPrompts = newValue } }
  }

  func botConversation(sessionId: UUID, before: Int?, limit: Int) async throws -> ServerBotConversationPage {
    try lock.withLock {
      guard !_pages.isEmpty else { throw CodevisorServerClientError.invalidResponse }
      return _pages.count == 1 ? _pages[0] : _pages.removeFirst()
    }
  }

  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?, clientId: String?
  ) async throws -> ServerPromptAccepted {
    try lock.withLock {
      if _failPrompts { throw CodevisorServerClientError.invalidResponse }
      _prompts.append(Prompt(text: text, messageId: messageId ?? ""))
    }
    return ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
  }

  func health() async throws -> ServerHealth { throw CodevisorServerClientError.invalidResponse }
  func info() async throws -> ServerInfo { throw CodevisorServerClientError.invalidResponse }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    throw CodevisorServerClientError.invalidResponse
  }
  func capabilities(cwd: String) async throws -> ServerCapabilities { throw CodevisorServerClientError.invalidResponse }
  func deleteProject(id: UUID) async throws {}
  func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    throw CodevisorServerClientError.invalidResponse
  }
  func upsertSession(_ session: ChatSession) async throws -> ServerSession {
    throw CodevisorServerClientError.invalidResponse
  }
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    try await promptSession(id: id, text: text, attachments: [], messageId: nil, clientId: nil)
  }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func listProjects() async throws -> [ServerProject] { [] }
  func listSessions() async throws -> [ServerSession] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }
  func updateSession(_ session: ChatSession) async throws -> ServerSession {
    throw CodevisorServerClientError.invalidResponse
  }
  func deleteSession(id: UUID) async throws {}
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { $0.finish() }
  }
}
