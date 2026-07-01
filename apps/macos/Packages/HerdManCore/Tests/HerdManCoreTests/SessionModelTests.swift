import Foundation
import Testing
import ACPKit
@testable import HerdManCore

@MainActor
@Suite("SessionModel")
struct SessionModelTests {
    private func makeModel(_ client: FakeACPClient) -> SessionModel {
        SessionModel(client: client, sessionId: "session", now: { Date(timeIntervalSince1970: 100) })
    }

    @Test("Sending appends the user message and a streamed assistant turn")
    func sendStreams() async {
        let client = FakeACPClient()
        client.scriptedUpdates = [
            .agentMessageChunk(.text("Hello")),
            .toolCall(ToolCall(toolCallId: "a", title: "Read")),
            .agentMessageChunk(.text("Done."))
        ]
        let model = makeModel(client)
        await model.send("hi there")

        #expect(model.conversation.count == 2)
        guard case let .user(user) = model.conversation[0] else { Issue.record("expected user"); return }
        #expect(user.text == "hi there")
        guard case let .assistant(assistant) = model.conversation[1] else { Issue.record("expected assistant"); return }
        #expect(assistant.turn.entries.map(\.id) == ["text:t0", "tool:a", "text:t1"])
        #expect(assistant.turn.isGenerating == false)
        #expect(assistant.turn.stopReason == .endTurn)
        #expect(assistant.turn.finalText == .text(id: "t1", markdown: "Done."))
        #expect(model.isSending == false)
    }

    @Test("Follow-up messages stream too (single long-lived consumer)")
    func followUpStreams() async {
        let client = FakeACPClient()
        client.scriptedUpdates = [.agentMessageChunk(.text("reply"))]
        let model = makeModel(client)

        await model.send("first")
        await model.send("second")

        #expect(model.conversation.count == 4)
        guard case let .assistant(first) = model.conversation[1] else { Issue.record("a1"); return }
        guard case let .assistant(second) = model.conversation[3] else { Issue.record("a2"); return }
        #expect(first.turn.finalText == .text(id: "t0", markdown: "reply"))
        // The follow-up turn must also receive its streamed content.
        #expect(second.turn.finalText == .text(id: "t0", markdown: "reply"))
        #expect(second.turn.isGenerating == false)
    }

    @Test("usage_update is captured as session cost + tokens")
    func usageCaptured() async {
        let client = FakeACPClient()
        client.scriptedUpdates = [
            .agentMessageChunk(.text("hi")),
            .usageUpdate(SessionUsage(used: 1234, size: 200_000, cost: SessionCost(amount: 0.05, currency: "USD")))
        ]
        let model = makeModel(client)
        await model.send("hi")
        #expect(model.usage?.used == 1234)
        #expect(model.usage?.size == 200_000)
        #expect(model.usage?.cost == SessionCost(amount: 0.05, currency: "USD"))
    }

    @Test("Composer text is cleared and used by send()")
    func composerSend() async {
        let client = FakeACPClient()
        client.scriptedUpdates = [.agentMessageChunk(.text("ok"))]
        let model = makeModel(client)
        model.composerText = "from composer"
        await model.send()
        #expect(model.composerText == "")
        guard case let .user(user) = model.conversation.first else { Issue.record("expected user"); return }
        #expect(user.text == "from composer")
    }

    @Test("Blank prompts are ignored")
    func blankIgnored() async {
        let client = FakeACPClient()
        let model = makeModel(client)
        await model.send("   ")
        #expect(model.conversation.isEmpty)
    }

    @Test("A prompt error is surfaced and the turn is finished")
    func promptError() async {
        let client = FakeACPClient()
        client.promptError = CustomError()
        let model = makeModel(client)
        await model.send("hello")
        #expect(model.errorMessage != nil)
        guard case let .assistant(assistant) = model.conversation.last else { Issue.record("expected assistant"); return }
        #expect(assistant.turn.isGenerating == false)
        #expect(model.isSending == false)
    }

    @Test("Available commands and mode updates are captured")
    func commandsAndMode() async {
        let client = FakeACPClient()
        client.scriptedUpdates = [
            .availableCommandsUpdate([AvailableCommand(name: "test", description: "run tests")]),
            .currentModeUpdate(currentModeId: "deep"),
            .agentMessageChunk(.text("done"))
        ]
        let model = SessionModel(
            client: client,
            sessionId: "session",
            modeState: SessionModeState(currentModeId: "fast", availableModes: [
                SessionMode(id: "fast", name: "Fast"), SessionMode(id: "deep", name: "Deep")
            ]),
            now: { Date(timeIntervalSince1970: 100) }
        )
        await model.send("go")
        #expect(model.availableCommands.map(\.name) == ["test"])
        #expect(model.modeState?.currentModeId == "deep")
    }

    @Test("Duration is recorded from the injected clock")
    func duration() async {
        let client = FakeACPClient()
        client.scriptedUpdates = [.agentMessageChunk(.text("hi"))]
        let times = TimeBox(values: [Date(timeIntervalSince1970: 10), Date(timeIntervalSince1970: 25)])
        let model = SessionModel(client: client, sessionId: "session", now: { times.next() })
        await model.send("go")
        guard case let .assistant(assistant) = model.conversation.last else { Issue.record("expected assistant"); return }
        #expect(assistant.turn.duration == 15)
    }

    @Test("cancel forwards to the client only while sending")
    func cancel() async {
        let client = FakeACPClient()
        let model = makeModel(client)
        await model.cancel() // not sending yet -> ignored
        #expect(client.cancelledSessions.isEmpty)
    }

    @Test("loadHistory rebuilds the conversation from replayed updates")
    func loadHistory() async throws {
        let client = FakeACPClient()
        client.scriptedUpdates = [
            .userMessageChunk(.text("what does this repo do")),
            .agentMessageChunk(.text("It is ")),
            .agentMessageChunk(.text("a game.")),
            .toolCall(ToolCall(toolCallId: "t", title: "Read README", kind: .read, status: .completed)),
            .userMessageChunk(.text("thanks")),
            .agentMessageChunk(.text("You're welcome."))
        ]
        let model = SessionModel(client: client, sessionId: "session", now: { Date(timeIntervalSince1970: 0) })
        _ = try await client.loadSession(LoadSessionRequest(sessionId: "session", cwd: "/x"))
        await model.loadHistory()

        #expect(model.conversation.count == 4)
        guard case let .user(u1) = model.conversation[0] else { Issue.record("expected user"); return }
        #expect(u1.text == "what does this repo do")
        guard case let .assistant(a1) = model.conversation[1] else { Issue.record("expected assistant"); return }
        #expect(a1.turn.finalText == nil) // ends on a tool call
        #expect(a1.turn.toolCalls.count == 1)
        #expect(a1.turn.isGenerating == false)
        guard case let .user(u2) = model.conversation[2] else { Issue.record("expected user"); return }
        #expect(u2.text == "thanks")
        guard case let .assistant(a2) = model.conversation[3] else { Issue.record("expected assistant"); return }
        #expect(a2.turn.finalText == .text(id: "t0", markdown: "You're welcome."))
    }

    @Test("Config options stream in and can be filtered by category")
    func configOptions() async {
        let client = FakeACPClient()
        let modelOption = SessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "a",
                                              options: [SessionConfigSelectOption(value: "a", name: "A")])
        client.scriptedUpdates = [.configOptionUpdate([modelOption]), .agentMessageChunk(.text("ok"))]
        let model = makeModel(client)
        await model.send("go")
        #expect(model.configOptions.count == 1)
        #expect(model.configOptions(category: "model").first?.id == "model")
        #expect(model.configOptions(category: "thought_level").isEmpty)
    }

    @Test("setConfigOption forwards to the client and applies the result")
    func setConfigOption() async {
        let client = FakeACPClient()
        client.configOptionsResult = [
            SessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "gpt-5.4",
                                options: [SessionConfigSelectOption(value: "gpt-5.4", name: "GPT-5.4")])
        ]
        let model = makeModel(client)
        await model.setConfigOption(configId: "model", value: "gpt-5.4")
        #expect(client.setConfigOptions.first?.configId == "model")
        #expect(client.setConfigOptions.first?.value == "gpt-5.4")
        #expect(model.configOptions.first?.currentValue == "gpt-5.4")
    }

    @Test("setConfigOption surfaces errors")
    func setConfigError() async {
        let client = FakeACPClient()
        client.setConfigError = CustomError()
        let model = makeModel(client)
        await model.setConfigOption(configId: "model", value: "x")
        #expect(model.errorMessage != nil)
    }

    @Test("setMode forwards and updates local state")
    func setMode() async {
        let client = FakeACPClient()
        let model = SessionModel(
            client: client,
            sessionId: "session",
            modeState: SessionModeState(currentModeId: "fast", availableModes: [SessionMode(id: "deep", name: "Deep")])
        )
        await model.setMode("deep")
        #expect(client.setModes == ["deep"])
        #expect(model.modeState?.currentModeId == "deep")
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
                text: "what changed?",
                createdAt: "2026-06-30T00:00:00.000Z",
                isGenerating: false
            ),
            ServerConversationItem(
                id: assistantItemId.uuidString,
                role: .assistant,
                text: "Server-backed ",
                createdAt: "2026-06-30T00:00:01.000Z",
                isGenerating: false
            ),
            ServerConversationItem(
                id: UUID().uuidString,
                role: .assistant,
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
        #expect(assistant.turn.finalText == .text(id: "t0", markdown: "Server-backed history."))
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
    private let workspaceId = UUID()
    private let stream: AsyncThrowingStream<ServerEventEnvelope, any Error>
    private let continuation: AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation
    private let lock = NSLock()

    private var _promptedTexts: [String] = []
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

    var configUpdates: [(String, String)] {
        lock.withLock { _configUpdates }
    }

    var eventSinceValues: [Int] {
        lock.withLock { _eventSinceValues }
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
    func listWorkspaces() async throws -> [ServerWorkspace] { [] }
    func upsertWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace { fatalError("unused") }
    func updateWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace { fatalError("unused") }
    func deleteWorkspace(id: UUID) async throws {}
    func listSessions() async throws -> [ServerSession] { [] }
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail {
        ServerSessionDetail(
            session: ServerSession(
                id: sessionId.uuidString,
                workspaceId: workspaceId.uuidString,
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

    func cancelSession(id: UUID) async throws {}
    func setSessionMode(id: UUID, modeId: String) async throws {}

    func setSessionConfig(id: UUID, configId: String, value: String) async throws {
        lock.withLock { _configUpdates.append((configId, value)) }
    }

    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        lock.withLock { _eventSinceValues.append(since) }
        return stream
    }
}
