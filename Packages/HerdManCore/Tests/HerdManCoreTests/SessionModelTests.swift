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
