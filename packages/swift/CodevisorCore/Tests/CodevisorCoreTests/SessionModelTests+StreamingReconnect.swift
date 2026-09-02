import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
    @Test("A new empty session negotiates the scoped stream before its first prompt")
    func newSessionFirstPromptUsesScopedStream() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.initialTranscriptPage = ServerTranscriptPage(
            items: [],
            nextBefore: nil,
            hasMore: false,
            eventCursor: 0
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistory()
        await model.send("first prompt")

        #expect(client.sessionEventSinceValues == [0])
        #expect(client.eventSinceValues.isEmpty)
        #expect(model.isSending == false)
        guard case let .assistant(assistant) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(assistant.turn.finalText == .text(id: "t0", markdown: "Echo: first prompt"))
        #expect(assistant.turn.stopReason == .endTurn)
    }

    @Test("Harness authentication failures remain distinguishable for recovery UI")
    func harnessAuthenticationFailureIsDistinguishable() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.send("hello")
        client.emit(
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.authRequired",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-15T00:00:00.000Z",
                payload: .object(["detail": .string("Your Codex sign-in expired.")])
            ))
        await settleUntil { model.errorRequiresHarnessAuthentication }

        #expect(model.errorMessage == "Your Codex sign-in expired.")
        #expect(model.errorRequiresHarnessAuthentication)

        await model.send("try again")
        #expect(model.errorRequiresHarnessAuthentication == false)
    }

    @Test("Paginated reconnect restores a blocking question at the stream cursor")
    func paginatedReconnectRestoresPendingQuestion() async {
        let sessionId = UUID()
        let assistantId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let question = QuestionRequest(
            questionId: "question-after-reconnect",
            questions: [
                QuestionSpec(
                    id: "choice",
                    question: "Continue?",
                    options: [QuestionOption(label: "Yes"), QuestionOption(label: "No")],
                    allowsOther: false
                )
            ]
        )
        client.initialTranscriptPage = ServerTranscriptPage(
            items: [
                ServerTranscriptItem(
                    id: assistantId.uuidString,
                    sessionId: sessionId.uuidString,
                    sequence: 0,
                    role: .assistant,
                    text: "",
                    createdAt: "2026-07-13T00:00:00.000Z",
                    updatedAt: "2026-07-13T00:00:01.000Z",
                    isGenerating: true,
                    hasDetails: true,
                    turnId: "turn-before-reconnect",
                    startedAt: "2026-07-13T00:00:00.000Z",
                    endedAt: nil,
                    stopReason: nil,
                    stopDetail: nil,
                    planDocument: nil,
                    attachments: nil,
                    revision: 2
                )
            ],
            nextBefore: nil,
            hasMore: false,
            eventCursor: 2,
            pendingQuestion: question,
            backgroundTasks: [
                BackgroundTaskInfo(
                    id: "task-after-reconnect",
                    description: "Run checks",
                    status: "running",
                    taskType: "shell"
                )
            ]
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistory()

        #expect(model.pendingQuestion == question)
        #expect(model.isSending)
        #expect(model.backgroundTasks.map(\.id) == ["task-after-reconnect"])
        #expect(model.hasBackgroundTaskSnapshot)
        await settleUntil { !client.sessionEventSinceValues.isEmpty }
        #expect(client.sessionEventSinceValues == [2])
        await model.answerQuestion(
            answers: ["choice": QuestionAnswerEntry(answers: ["Yes"])]
        )
        #expect(model.pendingQuestion == nil)
        #expect(client.questionAnswers.count == 1)
        #expect(client.questionAnswers.first?.0 == "question-after-reconnect")
    }

    @Test("Mid-stream restore adopts the live span identity so resumed deltas merge")
    func midStreamRestoreMergesResumedDeltas() async {
        let sessionId = UUID()
        let assistantId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.initialTranscriptPage = ServerTranscriptPage(
            items: [
                ServerTranscriptItem(
                    id: assistantId.uuidString,
                    sessionId: sessionId.uuidString,
                    sequence: 0,
                    role: .assistant,
                    text: "First half",
                    createdAt: "2026-07-18T00:00:00.000Z",
                    updatedAt: "2026-07-18T00:00:01.000Z",
                    isGenerating: true,
                    hasDetails: false,
                    turnId: "turn-1",
                    startedAt: "2026-07-18T00:00:00.000Z",
                    endedAt: nil,
                    stopReason: nil,
                    stopDetail: nil,
                    planDocument: nil,
                    attachments: nil,
                    messageId: "msg-1",
                    revision: 2
                )
            ],
            nextBefore: nil,
            hasMore: false,
            eventCursor: 2
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistory()
        await settleUntil { !client.sessionEventSinceValues.isEmpty }

        // The stream resumes the same provider message after the reopen.
        client.emit(
            ServerEventEnvelope(
                id: 3,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-18T00:00:02.000Z",
                payload: .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "messageId": .string("msg-1"),
                    "content": .object(["type": .string("text"), "text": .string(" second half")]),
                ])
            ))

        await settleUntil {
            if case let .assistant(message) = model.conversation.last,
                case let .text(_, markdown) = message.turn.finalText
            {
                return markdown == "First half second half"
            }
            return false
        }
        guard case let .assistant(message) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        // One merged span: the restored half must not survive as a separate
        // entry that would demote it into "Worked for".
        guard case let .text(id, markdown) = message.turn.finalText else {
            Issue.record("expected final text")
            return
        }
        #expect(id == "acp:msg-1")
        #expect(markdown == "First half second half")
        #expect(message.turn.entries.count == 1)
        #expect(message.turn.workedEntries.isEmpty)
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
        client.emit(
            ServerEventEnvelope(
                id: 10,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:10.000Z",
                payload: .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "messageId": .string("msg-final"),
                    "content": .object(["type": .string("text"), "text": .string("The repo is ")]),
                ])
            ))
        client.emit(
            ServerEventEnvelope(
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
                    "status": .string("completed"),
                ])
            ))
        client.emit(
            ServerEventEnvelope(
                id: 12,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:12.000Z",
                payload: .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "messageId": .string("msg-final"),
                    "content": .object(["type": .string("text"), "text": .string("a game.")]),
                ])
            ))
        client.emit(
            ServerEventEnvelope(
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
                    "status": .string("completed"),
                ])
            ))
        client.emit(
            ServerEventEnvelope(
                id: 14,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:14.000Z",
                payload: .object(["stopReason": .string("end_turn")])
            ))
        await settleAssistant(model) { assistant in
            assistant.turn.finalText == .text(id: "acp:msg-final", markdown: "The repo is a game.")
                && assistant.turn.workedEntries.map(\.id) == ["tool:readme", "tool:package"]
        }

        guard case let .assistant(assistant) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(assistant.turn.finalText == .text(id: "acp:msg-final", markdown: "The repo is a game."))
        #expect(assistant.turn.workedEntries.map(\.id) == ["tool:readme", "tool:package"])
    }
}
