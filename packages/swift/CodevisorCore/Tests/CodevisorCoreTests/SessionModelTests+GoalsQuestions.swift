import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
    @Test("Goal lifecycle: set, pause, resume, and clear round-trip optimistically")
    func goalLifecycle() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        let didSetGoal = await model.setGoal(
            objective: "ship goal mode",
            tokenBudget: .set(50_000)
        )
        #expect(didSetGoal)
        #expect(model.goal?.objective == "ship goal mode")
        #expect(model.goal?.status == .active)
        #expect(model.goal?.tokenBudget == 50_000)

        await model.pauseGoal()
        #expect(model.goal?.status == .paused)
        #expect(client.goalUpdates.last?.1 == .paused)
        // Pause must not touch the budget (keep semantics).
        #expect(client.goalUpdates.last?.2 == .keep)

        await model.resumeGoal()
        #expect(model.goal?.status == .active)

        await model.setGoal(tokenBudget: .clear)
        #expect(model.goal?.tokenBudget == nil)

        await model.clearGoal()
        #expect(model.goal == nil)
        #expect(client.goalClearCount == 1)
    }

    @Test("Transcript loading restores the goal snapshot at its event cursor")
    func transcriptLoadingRestoresGoalSnapshot() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.initialTranscriptPage = ServerTranscriptPage(
            items: [],
            nextBefore: nil,
            hasMore: false,
            eventCursor: 12,
            goal: SessionGoal(
                objective: "ship goal mode",
                status: .active,
                activity: .verifying,
                tokensUsed: 12_000,
                timeUsedSeconds: 42
            )
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistory()

        #expect(model.goal?.objective == "ship goal mode")
        #expect(model.goal?.activity == .verifying)
        for _ in 0..<20 {
            if !client.sessionEventSinceValues.isEmpty { break }
            await Task.yield()
        }
        #expect(client.sessionEventSinceValues == [12])
    }

    @Test("A goal-only session still streams agent-initiated turns")
    func goalOnlySessionStreams() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            now: { Date(timeIntervalSince1970: 100) }
        )
        // No send(), no loadHistory() — setting the goal must be enough to
        // subscribe to the event stream (goal auto-continuation turns are
        // agent-initiated).
        await model.setGoal(objective: "count to ten")
        client.emit(
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:00:00.000Z",
                payload: .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "messageId": .string("m1"),
                    "content": .object(["type": .string("text"), "text": .string("Working on it.")]),
                ])
            ))
        for _ in 0..<40 {
            await Task.yield()
            if !model.conversation.isEmpty { break }
        }
        guard case let .assistant(assistant) = model.conversation.last else {
            Issue.record("expected the streamed turn to render")
            return
        }
        #expect(assistant.turn.entries.isEmpty == false)
    }

    @Test("Goal errors surface without clobbering local goal state")
    func goalErrorSurfaces() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        let didSetGoal = await model.setGoal(objective: "goal fails")
        #expect(!didSetGoal)
        #expect(model.goal == nil)
        #expect(model.errorMessage != nil)
    }

    @Test("Server goal events update and clear the session goal")
    func serverGoalEvents() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.loadHistory()
        var goalEdges = 0
        model.onGoalChanged = { goalEdges += 1 }

        client.emit(
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:00:00.000Z",
                payload: .object([
                    "goal": .object([
                        "objective": .string("long haul"),
                        "status": .string("active"),
                        "tokenBudget": .null,
                        "tokensUsed": .number(1200),
                        "timeUsedSeconds": .number(42),
                        "createdAt": .string("2026-07-05T00:00:00.000Z"),
                        "updatedAt": .string("2026-07-05T00:01:00.000Z"),
                    ])
                ])
            ))
        for _ in 0..<20 {
            await Task.yield()
            if model.goal != nil { break }
        }
        #expect(model.goal?.objective == "long haul")
        #expect(model.goal?.tokenBudget == nil)
        #expect(model.goal?.tokensUsed == 1200)

        // Later accounting snapshot replaces, never accumulates.
        client.emit(
            ServerEventEnvelope(
                id: 2,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:02:00.000Z",
                payload: .object([
                    "goal": .object([
                        "objective": .string("long haul"),
                        "status": .string("budgetLimited"),
                        "tokenBudget": .number(10_000),
                        "tokensUsed": .number(10_000),
                        "timeUsedSeconds": .number(90),
                        "createdAt": .string("2026-07-05T00:00:00.000Z"),
                        "updatedAt": .string("2026-07-05T00:02:00.000Z"),
                    ])
                ])
            ))
        for _ in 0..<20 {
            await Task.yield()
            if model.goal?.status == .budgetLimited { break }
        }
        #expect(model.goal?.status == .budgetLimited)
        #expect(model.goal?.tokensUsed == 10_000)

        client.emit(
            ServerEventEnvelope(
                id: 3,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:03:00.000Z",
                payload: .object(["goalCleared": .bool(true)])
            ))
        for _ in 0..<20 {
            await Task.yield()
            if model.goal == nil { break }
        }
        #expect(model.goal == nil)
        #expect(goalEdges == 3)
    }

    @Test("Agent questions set pending state; answers post and resolution renders a card")
    func questionLifecycle() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        var actionRequiredCount = 0
        model.onActionRequired = { actionRequiredCount += 1 }
        await model.loadHistory()

        client.emit(
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:00:00.000Z",
                payload: .object([
                    "sessionUpdate": .string("question"),
                    "questionId": .string("q-1"),
                    "questions": .array([
                        .object([
                            "id": .string("approach"),
                            "header": .string("Approach"),
                            "question": .string("Which approach?"),
                            "allowsOther": .bool(true),
                            "options": .array([
                                .object(["label": .string("MVP first"), "description": .string("Fast.")]),
                                .object(["label": .string("Full design")]),
                            ]),
                        ])
                    ]),
                ])
            ))
        await settleUntil { model.pendingQuestion != nil }
        #expect(model.pendingQuestion?.questionId == "q-1")
        #expect(model.pendingQuestion?.questions.first?.options.count == 2)
        #expect(actionRequiredCount == 1)

        // Answer posts to the server and clears optimistically.
        await model.answerQuestion(answers: ["approach": QuestionAnswerEntry(answers: ["MVP first"])])
        #expect(model.pendingQuestion == nil)
        #expect(client.questionAnswers.count == 1)
        #expect(client.questionAnswers.first?.0 == "q-1")
        #expect(client.questionAnswers.first?.1 == "answered")

        // The provider's resolution event renders an inline question tool call.
        client.emit(
            ServerEventEnvelope(
                id: 2,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:00:01.000Z",
                payload: .object([
                    "sessionUpdate": .string("question_resolved"),
                    "questionId": .string("q-1"),
                    "outcome": .string("answered"),
                    "questions": .array([
                        .object([
                            "id": .string("approach"),
                            "question": .string("Which approach?"),
                            "allowsOther": .bool(true),
                            "options": .array([]),
                        ])
                    ]),
                    "answers": .object([
                        "approach": .object(["answers": .array([.string("MVP first")])])
                    ]),
                ])
            ))
        for _ in 0..<20 {
            await Task.yield()
            if case let .assistant(message) = model.conversation.last,
                message.turn.toolCalls.contains(where: { $0.kind == .question })
            {
                break
            }
        }
        guard case let .assistant(assistant) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        let questionCall = assistant.turn.toolCalls.first { $0.kind == .question }
        #expect(questionCall?.toolCallId == "question:q-1")
        #expect(questionCall?.title == "Which approach?")
        #expect(questionCall?.content == [.content(.text("MVP first"))])
    }

    @Test("Question resolution reports progress immediately and ignores duplicate submissions")
    func questionResolutionIsSingleFlight() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        client.holdQuestionAnswers(until: gate)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.loadHistory()

        client.emit(
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:00:00.000Z",
                payload: .object([
                    "sessionUpdate": .string("question"),
                    "questionId": .string("q-single-flight"),
                    "questions": .array([
                        .object([
                            "id": .string("choice"),
                            "question": .string("Continue?"),
                            "allowsOther": .bool(false),
                            "options": .array([.object(["label": .string("Yes")])]),
                        ])
                    ]),
                ])
            ))
        await settleUntil { model.pendingQuestion != nil }

        let first = Task {
            await model.answerQuestion(
                answers: ["choice": QuestionAnswerEntry(answers: ["Yes"])]
            )
        }
        await settleUntil { model.isResolvingQuestion }
        #expect(model.pendingQuestion?.questionId == "q-single-flight")
        await settleUntil { client.questionAnswers.count == 1 }
        #expect(client.questionAnswers.count == 1)

        await model.answerQuestion(
            answers: ["choice": QuestionAnswerEntry(answers: ["Yes"])]
        )
        #expect(client.questionAnswers.count == 1)

        release.yield(())
        release.finish()
        await first.value

        #expect(model.isResolvingQuestion == false)
        #expect(model.pendingQuestion == nil)
    }

    @Test("Cancelling a question posts the dismissal; turn end clears stale questions")
    func questionCancelAndTurnEnd() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.loadHistory()
        let questionEnvelope: (Int, String) -> ServerEventEnvelope = { id, questionId in
            ServerEventEnvelope(
                id: id,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:00:00.000Z",
                payload: .object([
                    "sessionUpdate": .string("question"),
                    "questionId": .string(questionId),
                    "questions": .array([
                        .object([
                            "id": .string("q"),
                            "question": .string("Pick?"),
                            "allowsOther": .bool(true),
                            "options": .array([.object(["label": .string("A")])]),
                        ])
                    ]),
                ])
            )
        }
        client.emit(questionEnvelope(1, "q-cancel"))
        for _ in 0..<20 {
            await Task.yield()
            if model.pendingQuestion != nil { break }
        }
        await model.cancelQuestion()
        #expect(model.pendingQuestion == nil)
        #expect(client.questionAnswers.first?.1 == "cancelled")

        // A stale question is dropped when the turn finishes, even if the
        // resolution event was lost.
        client.emit(questionEnvelope(2, "q-stale"))
        for _ in 0..<20 {
            await Task.yield()
            if model.pendingQuestion != nil { break }
        }
        client.emit(
            ServerEventEnvelope(
                id: 3,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-05T00:00:02.000Z",
                payload: .object(["stopReason": .string("end_turn")])
            ))
        for _ in 0..<20 {
            await Task.yield()
            if model.pendingQuestion == nil { break }
        }
        #expect(model.pendingQuestion == nil)
    }
}
