import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
    @Test("A turn that ends abnormally surfaces its stopDetail on the turn")
    func abnormalStopSurfacesDetail() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.send("do work")
        // The provider gave up recovering a transient failure and ends the turn
        // with a human reason attached to the turn-end event.
        client.emit(
            ServerEventEnvelope(
                id: 1, serverId: "local", kind: "session.updated",
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:00.000Z",
                payload: .object([
                    "stopReason": .string("end_turn"),
                    "stopDetail": .string("The Claude API was overloaded."),
                    "retryable": .bool(true),
                    "initiatedBy": .string("agent"),
                ])
            ))
        await settleUntil { model.isSending == false }

        guard case let .assistant(message) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(message.turn.stopDetail == "The Claude API was overloaded.")
        #expect(message.turn.retryable)
        #expect(message.turn.isGenerating == false)
        #expect(model.lastTurnInitiator == .agent)
        #expect(model.lastTurnEndedWithError)
    }

    @Test("A retryable session error stays attached to the failed turn")
    func retryableSessionErrorSurfacesOnTurn() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.send("do work")
        client.emit(
            ServerEventEnvelope(
                id: 1, serverId: "local", kind: "session.error",
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:00.000Z",
                payload: .object([
                    "message": .string("The provider connection failed."),
                    "retryable": .bool(true),
                ])
            ))
        await settleUntil { model.isSending == false }

        guard case let .assistant(message) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(message.turn.stopDetail == "The provider connection failed.")
        #expect(message.turn.retryable)
        #expect(model.errorMessage == "The provider connection failed.")
    }

    @Test("A restored-runtime failure preserves history and its recovery kind")
    func restoredRuntimeFailurePreservesHistory() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.initialTranscriptPage = ServerTranscriptPage(
            items: [
                ServerTranscriptItem(
                    id: UUID().uuidString,
                    sessionId: sessionId.uuidString,
                    sequence: 0,
                    role: .user,
                    text: "Keep this message visible.",
                    createdAt: "2026-06-30T00:00:00.000Z",
                    updatedAt: "2026-06-30T00:00:00.000Z",
                    isGenerating: false,
                    hasDetails: false,
                    revision: 1
                )
            ],
            hasMore: false,
            eventCursor: 0
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistory()
        model.recordSessionFailure(
            "Select a signed-in harness account before continuing this session",
            requiresHarnessAuthentication: true
        )

        #expect(userMessages(model).map(\.text) == ["Keep this message visible."])
        #expect(model.errorRequiresHarnessAuthentication)
        #expect(model.errorMessage == "Select a signed-in harness account before continuing this session")
    }

    @Test("A transient retry surfaces on the active turn and clears on new content")
    func retryStatusSurfacesThenClears() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.send("do work")
        // The provider reports it's retrying a transient failure (attempt 2 of 3).
        client.emit(
            ServerEventEnvelope(
                id: 1, serverId: "local", kind: "session.updated",
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:00.000Z",
                payload: .object([
                    "retrying": .object([
                        "attempt": .number(2),
                        "message": .string("Claude is overloaded, retrying"),
                        "of": .number(3),
                    ])
                ])
            ))
        await settleUntil {
            if case let .assistant(message) = model.conversation.last {
                return message.turn.retryStatus
                    == RetryStatus(
                        attempt: 2,
                        of: 3,
                        message: "Claude is overloaded, retrying"
                    )
            }
            return false
        }

        // The retry succeeds — new content clears the "Retrying…" status.
        client.emit(
            ServerEventEnvelope(
                id: 2, serverId: "local", kind: "session.output",
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:01.000Z",
                payload: .object(["role": .string("assistant"), "text": .string("recovered")])
            ))
        await settleUntil {
            if case let .assistant(message) = model.conversation.last {
                return message.turn.retryStatus == nil
            }
            return false
        }
        guard case let .assistant(message) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(message.turn.retryStatus == nil)
        #expect(message.turn.finalText == .text(id: "t0", markdown: "recovered"))
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

        client.emit(
            ServerEventEnvelope(
                id: 20,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:01:00.000Z",
                payload: .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "messageId": .string("bg-1"),
                    "content": .object(["type": .string("text"), "text": .string("Background task finished.")]),
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
        client.emit(
            ServerEventEnvelope(
                id: 3,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:03.000Z",
                payload: .object([
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string("edit-1"),
                    "status": .string("failed"),
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

    @Test("Plan updates drive the session-level todo panel and survive replay")
    func sessionPlanUpdates() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.historyEvents = [
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:00:00.000Z",
                payload: .object([
                    "sessionUpdate": .string("plan"),
                    "entries": .array([
                        .object([
                            "content": .string("Explore"),
                            "priority": .string("medium"),
                            "status": .string("completed"),
                        ]),
                        .object([
                            "content": .string("Implement"),
                            "priority": .string("medium"),
                            "status": .string("in_progress"),
                        ]),
                    ]),
                ])
            )
        ]
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.loadHistory()
        #expect(model.sessionPlan?.entries.count == 2)
        #expect(model.sessionPlan?.entries.last?.status == .inProgress)

        // A later snapshot replaces the session plan wholesale.
        client.emit(
            ServerEventEnvelope(
                id: 2,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:01:00.000Z",
                payload: .object([
                    "sessionUpdate": .string("plan"),
                    "entries": .array([
                        .object([
                            "content": .string("Ship it"),
                            "priority": .string("medium"),
                            "status": .string("pending"),
                        ])
                    ]),
                ])
            ))
        for _ in 0..<20 {
            await Task.yield()
            if model.sessionPlan?.entries.count == 1 { break }
        }
        #expect(model.sessionPlan?.entries.first?.content == "Ship it")
    }

    @Test("Plan documents survive history replay")
    func planDocumentReplays() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.historyEvents = [
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:00:00.000Z",
                payload: .object([
                    "sessionUpdate": .string("plan_document"),
                    "markdown": .string("# The Plan\n\n1. Do it"),
                ])
            ),
            ServerEventEnvelope(
                id: 2,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:00:01.000Z",
                payload: .object([
                    "sessionUpdate": .string("plan"),
                    "entries": .array([
                        .object([
                            "content": .string("Do it"),
                            "priority": .string("medium"),
                            "status": .string("in_progress"),
                        ])
                    ]),
                ])
            ),
            ServerEventEnvelope(
                id: 3,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:00:02.000Z",
                payload: .object(["stopReason": .string("end_turn")])
            ),
        ]
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            now: { Date(timeIntervalSince1970: 100) }
        )
        await model.loadHistory()
        guard case let .assistant(assistant) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(assistant.turn.planDocument == "# The Plan\n\n1. Do it")
        #expect(assistant.turn.plan?.entries.first?.status == .inProgress)
    }
}
