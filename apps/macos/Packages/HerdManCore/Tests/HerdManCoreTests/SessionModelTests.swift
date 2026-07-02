import Foundation
import Testing
import ACPKit
@testable import HerdManCore

@MainActor
@Suite("SessionModel")
struct SessionModelTests {
    @Test("Blank prompts are ignored")
    func blankIgnored() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.send("   ")
        #expect(model.conversation.isEmpty)
        #expect(client.promptedTexts.isEmpty)
    }

    @Test("cancel is ignored unless a turn is in flight")
    func cancelOnlyWhileSending() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.cancel()
        #expect(client.cancelCount == 0)
    }

    @Test("Server-backed sessions prompt through the server and consume event stream output")
    func serverBackedSendStreams() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            now: { Date(timeIntervalSince1970: 100) }
        )

        await model.send("hello server")

        #expect(client.promptedTexts == ["hello server"])
        #expect(model.conversation.count == 2)
        guard case let .assistant(assistant) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(assistant.turn.finalText == .text(id: "t0", markdown: "Echo: hello server"))
        #expect(assistant.turn.stopReason == .endTurn)
    }

    @Test("Server-backed loadHistory seeds materialized conversation and resumes from cursor")
    func serverBackedLoadHistorySeedsSnapshot() async {
        let sessionId = UUID()
        let userItemId = UUID()
        let assistantItemId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.detailCursor = 42
        client.detailConversation = [
            ServerConversationItem(
                id: userItemId.uuidString,
                role: .user,
                messageId: "user-1",
                text: "what changed?",
                createdAt: "2026-06-30T00:00:00.000Z",
                isGenerating: false
            ),
            ServerConversationItem(
                id: assistantItemId.uuidString,
                role: .assistant,
                messageId: "assistant-1",
                text: "Server-backed ",
                createdAt: "2026-06-30T00:00:01.000Z",
                isGenerating: false
            ),
            ServerConversationItem(
                id: UUID().uuidString,
                role: .assistant,
                messageId: "assistant-1",
                text: "history.",
                createdAt: "2026-06-30T00:00:02.000Z",
                isGenerating: false
            )
        ]
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistory()
        await Task.yield()

        #expect(client.eventSinceValues == [42])
        #expect(model.conversation.count == 2)
        guard case let .user(user) = model.conversation.first else {
            Issue.record("expected user")
            return
        }
        #expect(user.id == userItemId)
        #expect(user.text == "what changed?")
        guard case let .assistant(assistant) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(assistant.id == assistantItemId)
        #expect(assistant.turn.finalText == .text(id: "acp:assistant-1", markdown: "Server-backed history."))
    }

    @Test("Server-backed event stream keeps final answer visible after interleaved tool events")
    func serverBackedMessageIdsMergeInterleavedOutput() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            now: { Date(timeIntervalSince1970: 100) }
        )

        await model.loadHistory()
        client.emit(ServerEventEnvelope(
            id: 10,
            serverId: "local",
            kind: "session.output",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:10.000Z",
            payload: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "messageId": .string("msg-final"),
                "content": .object(["type": .string("text"), "text": .string("The repo is ")])
            ])
        ))
        client.emit(ServerEventEnvelope(
            id: 11,
            serverId: "local",
            kind: "session.output",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:11.000Z",
            payload: .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("readme"),
                "title": .string("Read README"),
                "kind": .string("read"),
                "status": .string("completed")
            ])
        ))
        client.emit(ServerEventEnvelope(
            id: 12,
            serverId: "local",
            kind: "session.output",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:12.000Z",
            payload: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "messageId": .string("msg-final"),
                "content": .object(["type": .string("text"), "text": .string("a game.")])
            ])
        ))
        client.emit(ServerEventEnvelope(
            id: 13,
            serverId: "local",
            kind: "session.output",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:13.000Z",
            payload: .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("package"),
                "title": .string("Read package"),
                "kind": .string("read"),
                "status": .string("completed")
            ])
        ))
        client.emit(ServerEventEnvelope(
            id: 14,
            serverId: "local",
            kind: "session.updated",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:14.000Z",
            payload: .object(["stopReason": .string("end_turn")])
        ))
        for _ in 0..<20 {
            await Task.yield()
            if case let .assistant(assistant) = model.conversation.last,
               assistant.turn.finalText == .text(id: "acp:msg-final", markdown: "The repo is a game."),
               assistant.turn.workedEntries.map(\.id) == ["tool:readme", "tool:package"] {
                break
            }
        }

        guard case let .assistant(assistant) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(assistant.turn.finalText == .text(id: "acp:msg-final", markdown: "The repo is a game."))
        #expect(assistant.turn.workedEntries.map(\.id) == ["tool:readme", "tool:package"])
    }

    @Test("Server-backed config updates are sent and reflected optimistically")
    func serverBackedConfigUpdate() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let option = SessionConfigOption(
            id: "model",
            name: "Model",
            category: "model",
            currentValue: "small",
            options: [
                SessionConfigSelectOption(value: "small", name: "Small"),
                SessionConfigSelectOption(value: "large", name: "Large")
            ]
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            configOptions: [option]
        )

        await model.setConfigOption(configId: "model", value: "large")

        #expect(client.configUpdates.count == 1)
        #expect(client.configUpdates.first?.0 == "model")
        #expect(client.configUpdates.first?.1 == "large")
        #expect(model.configOptions.first?.currentValue == "large")
    }
}

/// A clock that returns scripted timestamps in order, repeating the last value.
final class TimeBox: @unchecked Sendable {
    private let values: [Date]
    private var index = 0
    private let lock = NSLock()
    init(values: [Date]) { self.values = values }
    func next() -> Date {
        lock.withLock {
            let value = values[min(index, values.count - 1)]
            index += 1
            return value
        }
    }
}

private final class FakeSessionServerClient: HerdManServerClienting, @unchecked Sendable {
    private let sessionId: UUID
    private let projectId = UUID()
    private let stream: AsyncThrowingStream<ServerEventEnvelope, any Error>
    private let continuation: AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation
    private let lock = NSLock()

    private var _promptedTexts: [String] = []
    private var _cancelCount = 0
    private var _configUpdates: [(String, String)] = []
    private var _eventSinceValues: [Int] = []

    var detailConversation: [ServerConversationItem] = []
    var detailCursor = 0

    init(sessionId: UUID) {
        self.sessionId = sessionId
        (stream, continuation) = AsyncThrowingStream.makeStream(of: ServerEventEnvelope.self)
    }

    var promptedTexts: [String] {
        lock.withLock { _promptedTexts }
    }

    var cancelCount: Int {
        lock.withLock { _cancelCount }
    }

    var configUpdates: [(String, String)] {
        lock.withLock { _configUpdates }
    }

    var eventSinceValues: [Int] {
        lock.withLock { _eventSinceValues }
    }

    func emit(_ event: ServerEventEnvelope) {
        continuation.yield(event)
    }

    func health() async throws -> ServerHealth {
        ServerHealth(ok: true, version: "0.1.0", database: "ready")
    }

    func listHarnesses() async throws -> [ServerHarness] { [] }
    func info() async throws -> ServerInfo { fatalError("unused") }
    func updateInfo() async throws -> ServerUpdateInfo { fatalError("unused") }
    func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
    func listProjects() async throws -> [ServerProject] { [] }
    func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func deleteProject(id: UUID) async throws {}
    func listSessions() async throws -> [ServerSession] { [] }
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail {
        ServerSessionDetail(
            session: ServerSession(
                id: sessionId.uuidString,
                projectId: projectId.uuidString,
                serverId: "local",
                harnessId: "codex",
                agentSessionId: "agent-session",
                title: "Server session",
                origin: .herdman,
                isArchived: false,
                createdAt: "2026-06-30T00:00:00.000Z",
                updatedAt: nil,
                usage: nil
            ),
            conversation: detailConversation,
            eventCursor: detailCursor
        )
    }

    func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func deleteSession(id: UUID) async throws {}

    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        lock.withLock { _promptedTexts.append(text) }
        continuation.yield(ServerEventEnvelope(
            id: 1,
            serverId: "local",
            kind: "session.output",
            subjectId: id.uuidString,
            createdAt: "2026-06-30T00:00:00.000Z",
            payload: .object([
                "role": .string("assistant"),
                "text": .string("Echo: \(text)")
            ])
        ))
        continuation.yield(ServerEventEnvelope(
            id: 2,
            serverId: "local",
            kind: "session.updated",
            subjectId: id.uuidString,
            createdAt: "2026-06-30T00:00:01.000Z",
            payload: .object([
                "stopReason": .string("end_turn")
            ])
        ))
        return ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
    }

    func cancelSession(id: UUID) async throws {
        lock.withLock { _cancelCount += 1 }
    }
    func setSessionMode(id: UUID, modeId: String) async throws {}

    func setSessionConfig(id: UUID, configId: String, value: String) async throws {
        lock.withLock { _configUpdates.append((configId, value)) }
    }

    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        lock.withLock { _eventSinceValues.append(since) }
        return stream
    }
}
