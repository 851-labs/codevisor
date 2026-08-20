import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
    @Test("Background task snapshots drive the waiting indicator")
    func backgroundTaskWaiting() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        // Echoed prompt finishes the turn, so the session is idle. No
        // snapshot yet — tab pruning must not treat that as "no tasks".
        await model.send("run tests in the background")
        await settleUntil { !model.isSending }
        #expect(model.isSending == false)
        #expect(model.isWaitingOnBackgroundTasks == false)
        #expect(model.hasBackgroundTaskSnapshot == false)

        var runtimeEdges = 0
        model.onRuntimeStateChanged = { runtimeEdges += 1 }
        // The prompt echo consumed envelope ids 1-2; manual emits continue
        // the monotonic sequence from 3.
        client.emit(
            ServerEventEnvelope(
                id: 3,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:01.000Z",
                payload: .object(["runtimeState": .string("running")])
            ))
        await settleUntil { model.runtimeState == .running }
        #expect(model.isRuntimeIdle == false)
        client.emit(
            ServerEventEnvelope(
                id: 4,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:01.500Z",
                payload: .object(["runtimeState": .string("idle")])
            ))
        await settleUntil { model.isRuntimeIdle }
        #expect(runtimeEdges == 2)

        client.emit(
            ServerEventEnvelope(
                id: 5,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:02.000Z",
                payload: .object([
                    "backgroundTasks": .array([
                        .object([
                            "id": .string("bg-1"),
                            "description": .string("Run npm test"),
                            "status": .string("running"),
                            "taskType": .string("shell"),
                        ])
                    ])
                ])
            ))
        await settleUntil { !model.backgroundTasks.isEmpty }
        #expect(
            model.backgroundTasks == [
                BackgroundTaskInfo(id: "bg-1", description: "Run npm test", status: "running", taskType: "shell")
            ])
        #expect(model.isWaitingOnBackgroundTasks)
        #expect(model.hasBackgroundTaskSnapshot)

        // A task with an attachable terminal renders as a terminal tab, not
        // the waiting indicator: it is running, not being waited on.
        client.emit(
            ServerEventEnvelope(
                id: 6,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:02.500Z",
                payload: .object([
                    "backgroundTasks": .array([
                        .object([
                            "id": .string("bg-2"),
                            "description": .string("npm run dev"),
                            "status": .string("running"),
                            "taskType": .string("shell"),
                            "terminalKey": .string("\(sessionId.uuidString):bg:tool-1"),
                        ])
                    ])
                ])
            ))
        await settleUntil { model.backgroundTasks.first?.id == "bg-2" }
        #expect(
            model.backgroundTasks == [
                BackgroundTaskInfo(
                    id: "bg-2",
                    description: "npm run dev",
                    status: "running",
                    taskType: "shell",
                    terminalKey: "\(sessionId.uuidString):bg:tool-1"
                )
            ])
        #expect(model.waitingBackgroundTasks.isEmpty)
        #expect(model.isWaitingOnBackgroundTasks == false)

        // The empty replace-on-update snapshot clears the indicator.
        client.emit(
            ServerEventEnvelope(
                id: 7,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:03.000Z",
                payload: .object(["backgroundTasks": .array([])])
            ))
        await settleUntil { model.backgroundTasks.isEmpty }
        #expect(model.isWaitingOnBackgroundTasks == false)
    }

    @Test("A late settle for a subagent child merges into the finished turn")
    func lateChildSettleMerges() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.send("spawn an agent")
        client.emit(
            ServerEventEnvelope(
                id: 1, serverId: "local", kind: "session.output",
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:00.000Z",
                payload: .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("task-1"),
                    "title": .string("Agent: explore"),
                    "kind": .string("agent"),
                    "status": .string("in_progress"),
                ])
            ))
        client.emit(
            ServerEventEnvelope(
                id: 2, serverId: "local", kind: "session.output",
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:01.000Z",
                payload: .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("sub-1"),
                    "title": .string("Read"),
                    "status": .string("in_progress"),
                    "parentToolCallId": .string("task-1"),
                ])
            ))
        client.emit(
            ServerEventEnvelope(
                id: 3, serverId: "local", kind: "session.updated",
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:02.000Z",
                payload: .object(["stopReason": .string("end_turn")])
            ))
        await settleUntil { model.isSending == false }
        let countAfterFinish = model.conversation.count

        // The child's settle arrives after the turn ended, without parent
        // attribution — it must merge by id lookup, not open a new bubble.
        client.emit(
            ServerEventEnvelope(
                id: 4, serverId: "local", kind: "session.output",
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:03.000Z",
                payload: .object([
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string("sub-1"),
                    "status": .string("failed"),
                ])
            ))
        await settleUntil {
            if case let .assistant(message) = model.conversation.last,
                case let .tool(child)? = message.turn.subagents["task-1"]?.entries.first
            {
                return child.status == .failed
            }
            return false
        }
        #expect(model.conversation.count == countAfterFinish)
        guard case let .assistant(message) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(message.turn.isGenerating == false)
        guard case let .tool(child)? = message.turn.subagents["task-1"]?.entries.first else {
            Issue.record("expected nested child")
            return
        }
        #expect(child.status == .failed)
    }

    @Test("Background subagent output after turn end merges into the owning bubble")
    func crossTurnSubagentRouting() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.send("spawn a background agent")
        // The Agent tool call returns "launched" immediately and the turn ends.
        client.emit(
            ServerEventEnvelope(
                id: 1, serverId: "local", kind: "session.output",
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:00.000Z",
                payload: .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("task-1"),
                    "title": .string("Agent: explore"),
                    "kind": .string("agent"),
                    "status": .string("completed"),
                ])
            ))
        client.emit(
            ServerEventEnvelope(
                id: 2, serverId: "local", kind: "session.updated",
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:01.000Z",
                payload: .object(["stopReason": .string("end_turn")])
            ))
        await settleUntil { model.isSending == false }
        let bubblesAfterFinish = model.conversation.count

        // The subagent keeps streaming after the turn ended: prose and a
        // child tool call, both parented to the settled Agent call.
        client.emit(
            ServerEventEnvelope(
                id: 3, serverId: "local", kind: "session.output",
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:02.000Z",
                payload: .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("Here is my report.")]),
                    "messageId": .string("msg-late"),
                    "parentToolCallId": .string("task-1"),
                ])
            ))
        client.emit(
            ServerEventEnvelope(
                id: 4, serverId: "local", kind: "session.output",
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:03.000Z",
                payload: .object([
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string("sub-late"),
                    "title": .string("Read files"),
                    "status": .string("in_progress"),
                    "parentToolCallId": .string("task-1"),
                ])
            ))
        await settleUntil {
            if case let .assistant(message) = model.conversation.last {
                return message.turn.subagents["task-1"]?.entries.count == 2
            }
            return false
        }

        // No new bubble, the session stayed idle, and the owning bubble's
        // bucket holds both the prose and the child tool call.
        #expect(model.conversation.count == bubblesAfterFinish)
        #expect(model.isSending == false)
        guard case let .assistant(message) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(message.turn.isGenerating == false)
        #expect(
            message.turn.subagents["task-1"]?.entries == [
                .text(id: "acp:msg-late", markdown: "Here is my report."),
                .tool(
                    ToolCall(
                        toolCallId: "sub-late",
                        title: "Read files",
                        status: .inProgress,
                        parentToolCallId: "task-1"
                    )),
            ])
    }

    @Test("History replay rebuilds nested subagent transcripts and the last background snapshot wins")
    func historyReplaysNestingAndBackgroundTasks() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        func envelope(_ id: Int, _ kind: String, _ payload: JSONValue) -> ServerEventEnvelope {
            ServerEventEnvelope(
                id: id, serverId: "local", kind: kind,
                subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:00.000Z",
                payload: payload
            )
        }
        client.historyEvents = [
            envelope(
                1, "session.output",
                .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("task-1"),
                    "title": .string("Agent: explore"),
                    "kind": .string("agent"),
                    "status": .string("in_progress"),
                ])),
            envelope(
                2, "session.output",
                .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("child prose")]),
                    "messageId": .string("msg-sub"),
                    "parentToolCallId": .string("task-1"),
                ])),
            envelope(3, "session.updated", .object(["backgroundTasks": .array([])])),
            envelope(4, "session.updated", .object(["stopReason": .string("end_turn")])),
            envelope(
                5, "session.updated",
                .object([
                    "backgroundTasks": .array([
                        .object([
                            "id": .string("bg-9"),
                            "description": .string("Long build"),
                            "status": .string("running"),
                            "taskType": .string("shell"),
                        ])
                    ])
                ])),
        ]

        await model(client, sessionId: sessionId) { model in
            await model.loadHistory()
            guard case let .assistant(message) = model.conversation.last else {
                Issue.record("expected assistant")
                return
            }
            #expect(message.turn.entries.map(\.id) == ["tool:task-1"])
            #expect(message.turn.subagents["task-1"]?.entries == [.text(id: "acp:msg-sub", markdown: "child prose")])
            // Turn is settled, background work pending: waiting indicator on.
            #expect(model.isSending == false)
            #expect(model.backgroundTasks.map(\.id) == ["bg-9"])
            #expect(model.isWaitingOnBackgroundTasks)
        }
    }
}
