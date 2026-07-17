import Foundation
import Testing
@testable import ACPKit

@Suite("Protocol Codable")
struct ProtocolCodableTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try ACPJSON.encoder.encode(value)
        let decoded = try ACPJSON.decoder.decode(T.self, from: data)
        #expect(decoded == value)
    }

    @Test("ContentBlock variants round-trip")
    func contentBlocks() throws {
        try roundTrip(ContentBlock.text("hi", annotations: Annotations(audience: [.user], priority: 0.5)))
        try roundTrip(ContentBlock.image(data: "AAAA", mimeType: "image/png", uri: "file://x"))
        try roundTrip(ContentBlock.audio(data: "BBBB", mimeType: "audio/wav"))
        try roundTrip(ContentBlock.resourceLink(ResourceLink(name: "n", uri: "u", description: "d", mimeType: "text/plain", title: "t", size: 10)))
        try roundTrip(ContentBlock.resource(.text(uri: "u", text: "hello", mimeType: "text/plain")))
        try roundTrip(ContentBlock.resource(.blob(uri: "u", blob: "QkJCQg==", mimeType: nil)))
    }

    @Test("ContentBlock decodes by type discriminator")
    func contentBlockDiscriminator() throws {
        let data = Data(#"{"type":"text","text":"yo"}"#.utf8)
        let block = try ACPJSON.decoder.decode(ContentBlock.self, from: data)
        #expect(block.textValue == "yo")
    }

    @Test("Message chunk phase decodes leniently")
    func messageChunkPhase() throws {
        let tagged = Data(
            #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"},"messageId":"m1","phase":"final"}"#
                .utf8
        )
        let update = try ACPJSON.decoder.decode(SessionUpdate.self, from: tagged)
        guard case let .agentMessageChunk(_, _, _, phase) = update else {
            Issue.record("Expected agentMessageChunk")
            return
        }
        #expect(phase == .final)

        // Unknown phase values decode as nil rather than failing the update.
        let unknown = Data(
            #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"},"phase":"interlude"}"#
                .utf8
        )
        let lenient = try ACPJSON.decoder.decode(SessionUpdate.self, from: unknown)
        guard case let .agentMessageChunk(_, _, _, lenientPhase) = lenient else {
            Issue.record("Expected agentMessageChunk")
            return
        }
        #expect(lenientPhase == nil)
    }

    @Test("Unknown content block type throws")
    func unknownContentBlock() {
        #expect(throws: (any Error).self) {
            _ = try ACPJSON.decoder.decode(ContentBlock.self, from: Data(#"{"type":"video"}"#.utf8))
        }
    }

    @Test("SessionUpdate variants round-trip")
    func sessionUpdates() throws {
        try roundTrip(SessionUpdate.agentMessageChunk(.text("a")))
        try roundTrip(SessionUpdate.agentMessageChunk(.text("a"), messageId: "msg-1"))
        try roundTrip(SessionUpdate.agentMessageChunk(.text("a"), messageId: "msg-1", parentToolCallId: "task-1"))
        try roundTrip(SessionUpdate.agentMessageChunk(.text("a"), messageId: "msg-1", parentToolCallId: nil, phase: .final))
        try roundTrip(SessionUpdate.agentMessageChunk(.text(""), messageId: "msg-1", parentToolCallId: nil, phase: .commentary))
        try roundTrip(SessionUpdate.agentThoughtChunk(.text("thinking")))
        try roundTrip(SessionUpdate.agentThoughtChunk(.text("thinking"), messageId: "thought-1"))
        try roundTrip(SessionUpdate.agentThoughtChunk(.text("thinking"), messageId: nil, parentToolCallId: "task-1"))
        try roundTrip(SessionUpdate.userMessageChunk(.text("u")))
        try roundTrip(SessionUpdate.userMessageChunk(.text("u"), messageId: "user-1"))
        try roundTrip(SessionUpdate.toolCall(ToolCall(toolCallId: "t1", title: "Read", kind: .read, status: .pending)))
        try roundTrip(SessionUpdate.toolCallUpdate(ToolCallUpdate(toolCallId: "t1", status: .completed)))
        try roundTrip(SessionUpdate.plan(Plan(entries: [PlanEntry(content: "step", priority: .high, status: .pending)])))
        try roundTrip(SessionUpdate.availableCommandsUpdate([AvailableCommand(name: "test", description: "run")]))
        try roundTrip(SessionUpdate.currentModeUpdate(currentModeId: "fast"))
        try roundTrip(SessionUpdate.goalUpdate(SessionGoal(
            objective: "ship goal mode",
            status: .active,
            activity: .verifying,
            tokenBudget: 50_000,
            tokensUsed: 1_200,
            timeUsedSeconds: 42.125,
            createdAt: "2026-07-05T00:00:00.000Z",
            updatedAt: "2026-07-05T00:01:00.000Z"
        )))
        // Null budget (unbounded goal) survives the trip as nil.
        try roundTrip(SessionUpdate.goalUpdate(SessionGoal(objective: "unbounded", status: .paused)))
        try roundTrip(SessionUpdate.goalCleared)
        try roundTrip(SessionUpdate.contextCompaction(id: "compact-1", status: .started))
        try roundTrip(SessionUpdate.contextCompaction(id: "compact-1", status: .completed))
        try roundTrip(SessionUpdate.contextCompaction(id: nil, status: .failed))
        try roundTrip(SessionUpdate.planDocument(markdown: "# The Plan\n\n1. Do it"))
        try roundTrip(SessionUpdate.question(QuestionRequest(
            questionId: "q-1",
            message: "GitHub needs a few details.",
            questions: [
                QuestionSpec(
                    id: "approach",
                    header: "Approach",
                    question: "Which approach?",
                    options: [
                        QuestionOption(label: "MVP first (Recommended)", description: "Fast."),
                        QuestionOption(label: "Full design")
                    ],
                    multiSelect: false,
                    allowsOther: true
                )
            ],
            autoResolutionMs: 60_000
        )))
        try roundTrip(SessionUpdate.questionResolved(QuestionResolution(
            questionId: "q-1",
            outcome: .answered,
            questions: [QuestionSpec(id: "approach", question: "Which approach?")],
            answers: ["approach": QuestionAnswerEntry(answers: ["MVP first"], note: "keep it lean")]
        )))
        try roundTrip(SessionUpdate.questionResolved(QuestionResolution(
            questionId: "q-2",
            outcome: .cancelled,
            questions: []
        )))
    }

    @Test("Goal update decodes a null token budget and rejects unknown statuses")
    func goalDecoding() throws {
        let data = Data("""
        {"sessionUpdate":"goal_update","goal":{"objective":"o","status":"budgetLimited",\
        "tokenBudget":null,"tokensUsed":5,"timeUsedSeconds":9.25,"createdAt":"c","updatedAt":"u"}}
        """.utf8)
        let update = try ACPJSON.decoder.decode(SessionUpdate.self, from: data)
        guard case .goalUpdate(let goal) = update else { Issue.record("expected goal_update"); return }
        #expect(goal.tokenBudget == nil)
        #expect(goal.status == .budgetLimited)
        #expect(goal.timeUsedSeconds == 9.25)

        let unknownStatus = Data("""
        {"sessionUpdate":"goal_update","goal":{"objective":"o","status":"someday",\
        "tokensUsed":0,"timeUsedSeconds":0,"createdAt":"c","updatedAt":"u"}}
        """.utf8)
        #expect(throws: (any Error).self) {
            _ = try ACPJSON.decoder.decode(SessionUpdate.self, from: unknownStatus)
        }
    }

    @Test("SessionMode round-trips its canonical id")
    func sessionModeCanonicalId() throws {
        try roundTrip(SessionMode(id: "plan", name: "Plan", description: "d", canonicalId: "plan"))
        try roundTrip(SessionMode(id: "goal", name: "Goal mode"))
    }

    @Test("tool_call update carries inline fields")
    func toolCallInline() throws {
        let data = Data(#"{"sessionUpdate":"tool_call","toolCallId":"x","title":"Search","kind":"search","status":"in_progress"}"#.utf8)
        let update = try ACPJSON.decoder.decode(SessionUpdate.self, from: data)
        guard case .toolCall(let call) = update else { Issue.record("expected tool_call"); return }
        #expect(call.toolCallId == "x")
        #expect(call.kind == .search)
        #expect(call.status == .inProgress)
    }

    @Test("Unknown session update throws")
    func unknownUpdate() {
        #expect(throws: (any Error).self) {
            _ = try ACPJSON.decoder.decode(SessionUpdate.self, from: Data(#"{"sessionUpdate":"???"}"#.utf8))
        }
    }

    @Test("SessionNotification round-trips with nested update")
    func sessionNotification() throws {
        try roundTrip(SessionNotification(sessionId: "s1", update: .agentMessageChunk(.text("hi"))))
    }

    @Test("ToolCallContent variants round-trip")
    func toolCallContent() throws {
        try roundTrip(ToolCallContent.content(.text("out")))
        try roundTrip(ToolCallContent.diff(path: "/a.txt", oldText: "x", newText: "y"))
        try roundTrip(ToolCallContent.terminal(terminalId: "term-1"))
    }

    @Test("Unknown tool call content throws")
    func unknownToolCallContent() {
        #expect(throws: (any Error).self) {
            _ = try ACPJSON.decoder.decode(ToolCallContent.self, from: Data(#"{"type":"zzz"}"#.utf8))
        }
    }

    @Test("McpServer variants round-trip and default to stdio")
    func mcpServers() throws {
        try roundTrip(McpServer.stdio(name: "fs", command: "node", args: ["server.js"], env: [EnvVariable(name: "K", value: "V")]))
        try roundTrip(McpServer.http(name: "h", url: "https://x", headers: [HTTPHeader(name: "A", value: "B")]))
        try roundTrip(McpServer.sse(name: "s", url: "https://y", headers: []))
        // Missing type defaults to stdio.
        let data = Data(#"{"name":"fs","command":"node"}"#.utf8)
        let server = try ACPJSON.decoder.decode(McpServer.self, from: data)
        guard case .stdio(let name, let command, _, _) = server else { Issue.record("expected stdio"); return }
        #expect(name == "fs")
        #expect(command == "node")
    }

    @Test("Unknown MCP server type throws")
    func unknownMcp() {
        #expect(throws: (any Error).self) {
            _ = try ACPJSON.decoder.decode(McpServer.self, from: Data(#"{"type":"grpc","name":"x"}"#.utf8))
        }
    }

    @Test("ToolKind decodes unknown values as other")
    func toolKindLenient() throws {
        let kind = try ACPJSON.decoder.decode(ToolKind.self, from: Data("\"telepathy\"".utf8))
        #expect(kind == .other)
        let known = try ACPJSON.decoder.decode(ToolKind.self, from: Data("\"execute\"".utf8))
        #expect(known == .execute)
    }
}
