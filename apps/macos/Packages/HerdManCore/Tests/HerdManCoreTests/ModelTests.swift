import Foundation
import Testing
import ACPKit
@testable import HerdManCore

@Suite("Domain models")
struct ModelTests {
    @Test("Workspace derives its name from the folder")
    func workspaceFromFolder() {
        let workspace = Workspace.fromFolder(URL(fileURLWithPath: "/Users/x/Projects/HerdMan"))
        #expect(workspace.name == "HerdMan")
        #expect(workspace.isArchived == false)
    }

    @Test("Workspace and session encode and decode")
    func codable() throws {
        let workspace = Workspace(name: "W", folderURL: URL(fileURLWithPath: "/w"))
        let session = ChatSession(workspaceId: workspace.id, title: "S")
        let workspaceData = try JSONEncoder().encode(workspace)
        let sessionData = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(Workspace.self, from: workspaceData) == workspace)
        #expect(try JSONDecoder().decode(ChatSession.self, from: sessionData) == session)
    }

    @Test("TranscriptEntry identities are unique by kind and id")
    func entryIdentity() {
        #expect(TranscriptEntry.text(id: "1", markdown: "x").id == "text:1")
        #expect(TranscriptEntry.tool(ToolCall(toolCallId: "1", title: "t")).id == "tool:1")
        #expect(TranscriptEntry.text(id: "1", markdown: "x").isText)
        #expect(!TranscriptEntry.tool(ToolCall(toolCallId: "1", title: "t")).isText)
    }

    @Test("ConversationItem id mirrors the wrapped message")
    func conversationItemIdentity() {
        let user = UserMessage(text: "hi")
        let assistant = AssistantMessage(turn: AssistantTurn())
        #expect(ConversationItem.user(user).id == user.id)
        #expect(ConversationItem.assistant(assistant).id == assistant.id)
    }

    @Test("Empty turn has no final text and no worked content")
    func emptyTurn() {
        let turn = AssistantTurn()
        #expect(turn.finalText == nil)
        #expect(turn.workedEntries.isEmpty)
        #expect(turn.hasWorkedContent == false)
        #expect(turn.toolCalls.isEmpty)
    }
}
