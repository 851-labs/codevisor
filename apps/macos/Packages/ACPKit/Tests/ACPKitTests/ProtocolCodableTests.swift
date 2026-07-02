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
        try roundTrip(SessionUpdate.agentThoughtChunk(.text("thinking")))
        try roundTrip(SessionUpdate.agentThoughtChunk(.text("thinking"), messageId: "thought-1"))
        try roundTrip(SessionUpdate.userMessageChunk(.text("u")))
        try roundTrip(SessionUpdate.userMessageChunk(.text("u"), messageId: "user-1"))
        try roundTrip(SessionUpdate.toolCall(ToolCall(toolCallId: "t1", title: "Read", kind: .read, status: .pending)))
        try roundTrip(SessionUpdate.toolCallUpdate(ToolCallUpdate(toolCallId: "t1", status: .completed)))
        try roundTrip(SessionUpdate.plan(Plan(entries: [PlanEntry(content: "step", priority: .high, status: .pending)])))
        try roundTrip(SessionUpdate.availableCommandsUpdate([AvailableCommand(name: "test", description: "run")]))
        try roundTrip(SessionUpdate.currentModeUpdate(currentModeId: "fast"))
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
