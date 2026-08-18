import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
    @Test("Server-backed config updates paint before the request completes")
    func serverBackedConfigUpdate() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let (gate, continuation) = AsyncStream.makeStream(of: Void.self)
        client.holdConfigUpdates(until: gate)
        let option = SessionConfigOption(
            id: "model",
            name: "Model",
            category: "model",
            currentValue: "small",
            options: [
                SessionConfigSelectOption(value: "small", name: "Small"),
                SessionConfigSelectOption(value: "large", name: "Large"),
            ]
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            configOptions: [option]
        )

        let update = Task { await model.setConfigOption(configId: "model", value: "large") }
        await settleUntil { !client.configUpdates.isEmpty }

        #expect(client.configUpdates.count == 1)
        #expect(client.configUpdates.first?.0 == "model")
        #expect(client.configUpdates.first?.1 == "large")
        #expect(model.configOptions.first?.currentValue == "large")

        continuation.yield()
        continuation.finish()
        #expect(await update.value)
    }

    @Test("A rejected config update rolls back its optimistic selection")
    func rejectedServerBackedConfigUpdate() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.failNextConfigUpdate()
        let option = SessionConfigOption(
            id: "effort",
            name: "Reasoning",
            category: "thought_level",
            currentValue: "low",
            options: [
                SessionConfigSelectOption(value: "low", name: "Low"),
                SessionConfigSelectOption(value: "xhigh", name: "X-High"),
            ]
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            configOptions: [option]
        )

        let accepted = await model.setConfigOption(configId: "effort", value: "xhigh")

        #expect(!accepted)
        #expect(model.configOptions.first?.currentValue == "low")
    }

    @Test("Fresh harness capabilities replace draft model options")
    func refreshedCapabilitiesReplaceConfigOptions() {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let original = SessionConfigOption(
            id: "model",
            name: "Model",
            category: "model",
            currentValue: "old",
            options: [SessionConfigSelectOption(value: "old", name: "Old")]
        )
        let refreshed = SessionConfigOption(
            id: "model",
            name: "Model",
            category: "model",
            currentValue: "new",
            options: [SessionConfigSelectOption(value: "new", name: "New")]
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            configOptions: [original]
        )

        model.replaceConfigOptions([refreshed])

        #expect(model.configOptions == [refreshed])
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
                    "diffStats": .array([
                        .object([
                            "path": .string("a.txt"), "added": .number(3), "removed": .number(1),
                        ])
                    ]),
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
                    "content": .object(["type": .string("text"), "text": .string("Done.")]),
                ])
            ),
            ServerEventEnvelope(
                id: 4,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:03.000Z",
                payload: .object(["stopReason": .string("end_turn")])
            ),
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
        await settleUntil { !client.eventSinceValues.isEmpty }
        #expect(client.eventSinceValues == [4])
    }

    @Test("History restores selections without replacing the current config catalog")
    func historyKeepsCurrentConfigCatalog() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.historyEvents = [
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-09T18:23:30.000Z",
                payload: .object([
                    "configOptions": .array([
                        .object([
                            "id": .string("model"),
                            "name": .string("Model"),
                            "category": .string("model"),
                            "currentValue": .string("gpt-5.5"),
                            "options": .array([
                                .object(["value": .string("gpt-5.5"), "name": .string("GPT-5.5")]),
                                .object(["value": .string("gpt-5.4"), "name": .string("GPT-5.4")]),
                            ]),
                        ]),
                        .object([
                            "id": .string("effort"),
                            "name": .string("Reasoning"),
                            "category": .string("thought_level"),
                            "currentValue": .string("xhigh"),
                            "options": .array([
                                .object(["value": .string("low"), "name": .string("Low")]),
                                .object(["value": .string("xhigh"), "name": .string("X-High")]),
                            ]),
                        ]),
                    ])
                ])
            )
        ]
        let currentOptions = [
            SessionConfigOption(
                id: "model",
                name: "Model",
                category: "model",
                currentValue: "gpt-5.6-sol",
                options: [
                    SessionConfigSelectOption(value: "gpt-5.6-sol", name: "GPT-5.6-Sol"),
                    SessionConfigSelectOption(value: "gpt-5.5", name: "GPT-5.5"),
                    SessionConfigSelectOption(value: "gpt-5.6-terra", name: "GPT-5.6-Terra"),
                ]
            ),
            SessionConfigOption(
                id: "effort",
                name: "Reasoning",
                category: "thought_level",
                currentValue: "high",
                options: [
                    SessionConfigSelectOption(value: "low", name: "Low"),
                    SessionConfigSelectOption(value: "high", name: "High"),
                    SessionConfigSelectOption(value: "xhigh", name: "X-High"),
                ]
            ),
        ]
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            configOptions: currentOptions
        )

        await model.loadHistory()

        let modelOption = model.configOptions.first { $0.id == "model" }
        #expect(modelOption?.options.map(\.value) == ["gpt-5.6-sol", "gpt-5.5", "gpt-5.6-terra"])
        #expect(modelOption?.currentValue == "gpt-5.5")
        #expect(model.configOptions.first { $0.id == "effort" }?.currentValue == "xhigh")
        #expect(client.configUpdates.map(\.0) == ["model", "effort"])
    }
}
