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

    @Test("Attachments allow empty text and ride the prompt to the server")
    func attachmentsRidePrompt() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        let attachment = Attachment(
            fileId: "file-1", name: "shot.png", mimeType: "image/png", sizeBytes: 3, kind: .image
        )

        await model.send("", attachments: [attachment])

        #expect(client.promptedTexts == [""])
        #expect(client.promptedAttachments == [[attachment.serverRef]])
        guard case let .user(user) = model.conversation.first else {
            Issue.record("expected user")
            return
        }
        #expect(user.attachments == [attachment])
    }

    @Test("Replayed user events stamp attachments onto the optimistic echo and append remote ones")
    func userEventsCarryAttachments() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        let refPayload: JSONValue = .array([
            .object([
                "fileId": .string("file-9"),
                "name": .string("shot.png"),
                "mimeType": .string("image/png"),
                "sizeBytes": .number(3),
                "kind": .string("image")
            ])
        ])
        let expected = Attachment(
            fileId: "file-9", name: "shot.png", mimeType: "image/png", sizeBytes: 3, kind: .image
        )

        // The optimistic message has no attachments; the server echo does —
        // the echo's refs are stamped onto it instead of appending a dupe.
        await model.send("look at this")
        client.emit(ServerEventEnvelope(
            id: 1,
            serverId: "local",
            kind: "session.output",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:00.000Z",
            payload: .object([
                "role": .string("user"),
                "text": .string("look at this"),
                "attachments": refPayload
            ])
        ))
        await settleUntil { userMessages(model).first?.attachments.isEmpty == false }
        #expect(userMessages(model).count == 1)
        #expect(userMessages(model).first?.attachments == [expected])

        // A remote user message with attachments but no text still appends.
        client.emit(ServerEventEnvelope(
            id: 2,
            serverId: "local",
            kind: "session.output",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:01.000Z",
            payload: .object([
                "role": .string("user"),
                "text": .string(""),
                "attachments": refPayload
            ])
        ))
        await settleUntil { userMessages(model).count == 2 }
        #expect(userMessages(model).last?.text == "")
        #expect(userMessages(model).last?.attachments == [expected])
    }

    @Test("History snapshot conversation items carry attachments")
    func snapshotCarriesAttachments() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.detailConversation = [
            ServerConversationItem(
                id: UUID().uuidString,
                role: .user,
                messageId: nil,
                text: "with file",
                createdAt: "2026-06-30T00:00:00.000Z",
                isGenerating: false,
                attachments: [
                    ServerAttachmentRef(
                        fileId: "file-3", name: "doc.pdf", mimeType: "application/pdf",
                        sizeBytes: 9, kind: .file
                    )
                ]
            )
        ]
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistory()

        #expect(userMessages(model).first?.attachments == [
            Attachment(fileId: "file-3", name: "doc.pdf", mimeType: "application/pdf", sizeBytes: 9, kind: .file)
        ])
    }

    @Test("Attachment refs decode when present and stay nil for older servers")
    func attachmentDecodeBackwardCompat() throws {
        let legacy = try JSONDecoder().decode(
            ServerConversationItem.self,
            from: Data(#"{"id":"a","role":"user","text":"hi","createdAt":"t","isGenerating":false}"#.utf8)
        )
        #expect(legacy.attachments == nil)

        let modern = try JSONDecoder().decode(
            ServerPromptQueueItem.self,
            from: Data(
                #"{"id":"q","sessionId":"s","text":"hi","createdAt":"t","updatedAt":"t","attachments":[{"fileId":"f","name":"n.png","mimeType":"image/png","sizeBytes":1,"kind":"image"}]}"#
                    .utf8
            )
        )
        #expect(modern.attachments?.first?.fileId == "f")
        #expect(modern.attachments?.first?.attachment.kind == .image)
    }

    private func settleUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
    }

    private func userMessages(_ model: SessionModel) -> [UserMessage] {
        model.conversation.compactMap { item in
            if case let .user(message) = item { return message }
            return nil
        }
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

    @Test("Turn end settles in-flight tool calls by outcome")
    func settlesToolCallsOnFinish() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            now: { Date(timeIntervalSince1970: 100) }
        )
        await model.loadHistory()
        client.emit(toolCallEnvelope(id: 1, sessionId: sessionId, toolCallId: "edit-1", status: "in_progress"))
        client.emit(stopEnvelope(id: 2, sessionId: sessionId, stopReason: "cancelled"))
        await settleYields(model) { assistant in
            assistant.turn.toolCalls.first?.status == .cancelled
        }
        guard case let .assistant(assistant) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(assistant.turn.toolCalls.first?.status == .cancelled)
        #expect(assistant.turn.isGenerating == false)
        #expect(model.isSending == false)
    }

    @Test("Output after a finished turn opens a new agent-initiated turn")
    func agentInitiatedTurn() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            now: { Date(timeIntervalSince1970: 100) }
        )
        await model.send("kick off background work")
        let countAfterPrompt = model.conversation.count

        client.emit(ServerEventEnvelope(
            id: 20,
            serverId: "local",
            kind: "session.output",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:01:00.000Z",
            payload: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "messageId": .string("bg-1"),
                "content": .object(["type": .string("text"), "text": .string("Background task finished.")])
            ])
        ))
        client.emit(stopEnvelope(id: 21, sessionId: sessionId, stopReason: "end_turn"))
        await settleYields(model) { assistant in
            assistant.turn.finalText == .text(id: "acp:bg-1", markdown: "Background task finished.")
                && !assistant.turn.isGenerating
        }

        #expect(model.conversation.count == countAfterPrompt + 1)
        guard case let .assistant(background) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(background.turn.finalText == .text(id: "acp:bg-1", markdown: "Background task finished."))
        #expect(background.turn.isGenerating == false)
        #expect(model.isSending == false)
    }

    @Test("A straggler tool update merges into the finished turn without reopening it")
    func stragglerUpdateDoesNotReopen() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            now: { Date(timeIntervalSince1970: 100) }
        )
        await model.loadHistory()
        client.emit(toolCallEnvelope(id: 1, sessionId: sessionId, toolCallId: "edit-1", status: "in_progress"))
        client.emit(stopEnvelope(id: 2, sessionId: sessionId, stopReason: "end_turn"))
        client.emit(ServerEventEnvelope(
            id: 3,
            serverId: "local",
            kind: "session.output",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:03.000Z",
            payload: .object([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("edit-1"),
                "status": .string("failed")
            ])
        ))
        await settleYields(model) { assistant in
            assistant.turn.toolCalls.first?.status == .failed
        }

        #expect(model.conversation.count == 1)
        guard case let .assistant(assistant) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(assistant.turn.toolCalls.first?.status == .failed)
        #expect(assistant.turn.isGenerating == false)
        #expect(model.isSending == false)
    }

    @Test("loadHistory replays persisted events, rebuilding tool calls")
    func loadHistoryReplaysEvents() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.detailCursor = 99
        client.historyEvents = [
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:00.000Z",
                payload: .object(["role": .string("user"), "text": .string("edit the file")])
            ),
            ServerEventEnvelope(
                id: 2,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:01.000Z",
                payload: .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("edit-1"),
                    "title": .string("Edited a.txt"),
                    "kind": .string("edit"),
                    "status": .string("completed"),
                    "diffStats": .array([.object([
                        "path": .string("a.txt"), "added": .number(3), "removed": .number(1)
                    ])])
                ])
            ),
            ServerEventEnvelope(
                id: 3,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:02.000Z",
                payload: .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "messageId": .string("m1"),
                    "content": .object(["type": .string("text"), "text": .string("Done.")])
                ])
            ),
            ServerEventEnvelope(
                id: 4,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:03.000Z",
                payload: .object(["stopReason": .string("end_turn")])
            )
        ]
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            now: { Date(timeIntervalSince1970: 100) }
        )

        await model.loadHistory()

        #expect(model.conversation.count == 2)
        guard case let .user(user) = model.conversation.first else {
            Issue.record("expected user")
            return
        }
        #expect(user.text == "edit the file")
        guard case let .assistant(assistant) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(assistant.turn.toolCalls.count == 1)
        #expect(assistant.turn.toolCalls.first?.diffStats?.first?.added == 3)
        #expect(assistant.turn.finalText == .text(id: "acp:m1", markdown: "Done."))
        #expect(assistant.turn.isGenerating == false)
        #expect(model.isSending == false)
        // Live streaming resumes after the last replayed envelope, not the
        // snapshot cursor. The consumer task connects asynchronously.
        for _ in 0..<200 {
            await Task.yield()
            if !client.eventSinceValues.isEmpty { break }
        }
        #expect(client.eventSinceValues == [4])
    }

    private func toolCallEnvelope(id: Int, sessionId: UUID, toolCallId: String, status: String) -> ServerEventEnvelope {
        ServerEventEnvelope(
            id: id,
            serverId: "local",
            kind: "session.output",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:00.000Z",
            payload: .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string(toolCallId),
                "title": .string("Edited file"),
                "kind": .string("edit"),
                "status": .string(status)
            ])
        )
    }

    private func stopEnvelope(id: Int, sessionId: UUID, stopReason: String) -> ServerEventEnvelope {
        ServerEventEnvelope(
            id: id,
            serverId: "local",
            kind: "session.updated",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:01.000Z",
            payload: .object(["stopReason": .string(stopReason)])
        )
    }

    /// Yields until the model's last assistant turn satisfies the predicate
    /// (bounded), so emitted stream events land before assertions run.
    private func settleYields(_ model: SessionModel, until predicate: (AssistantMessage) -> Bool) async {
        for _ in 0..<200 {
            await Task.yield()
            if case let .assistant(assistant) = model.conversation.last, predicate(assistant) {
                return
            }
        }
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
    private var _promptedAttachments: [[ServerAttachmentRef]] = []
    private var _cancelCount = 0
    private var _configUpdates: [(String, String)] = []
    private var _eventSinceValues: [Int] = []

    var detailConversation: [ServerConversationItem] = []
    var detailCursor = 0
    var historyEvents: [ServerEventEnvelope] = []
    /// When false, prompts are accepted without the scripted assistant echo,
    /// leaving the turn generating so tests can emit their own events.
    var echoOnPrompt = true

    init(sessionId: UUID) {
        self.sessionId = sessionId
        (stream, continuation) = AsyncThrowingStream.makeStream(of: ServerEventEnvelope.self)
    }

    var promptedTexts: [String] {
        lock.withLock { _promptedTexts }
    }

    var promptedAttachments: [[ServerAttachmentRef]] {
        lock.withLock { _promptedAttachments }
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

    func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted {
        lock.withLock { _promptedAttachments.append(attachments) }
        return try await promptSession(id: id, text: text)
    }

    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        lock.withLock { _promptedTexts.append(text) }
        guard echoOnPrompt else {
            return ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
        }
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

    func sessionEvents(id: UUID) async throws -> [ServerEventEnvelope] {
        historyEvents
    }

    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        lock.withLock { _eventSinceValues.append(since) }
        return stream
    }
}
