import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@Suite("Domain models")
struct ModelTests {
    @Test("Harness auth terminal prefers its attach key and supports older servers")
    func harnessAuthTerminalAttachKey() throws {
        let current = try JSONDecoder().decode(
            ServerHarnessAuthFlow.self,
            from: Data(#"{"id":"flow-1","accountId":"account-1","kind":"terminal","terminalId":"terminal-1","terminalKey":"auth:flow-1"}"#.utf8)
        )
        let legacy = try JSONDecoder().decode(
            ServerHarnessAuthFlow.self,
            from: Data(#"{"id":"flow-1","accountId":"account-1","kind":"terminal","terminalId":"terminal-1"}"#.utf8)
        )

        #expect(current.terminalAttachKey == "auth:flow-1")
        #expect(legacy.terminalAttachKey == "terminal-1")
    }

    @Test("Project derives its name from the folder")
    func projectFromFolder() {
        let project = Project.fromFolder(URL(fileURLWithPath: "/Users/x/Projects/Codevisor"))
        #expect(project.name == "Codevisor")
        #expect(project.isArchived == false)
    }

    @Test("Project and session encode and decode")
    func codable() throws {
        let project = Project.fromFolder(URL(fileURLWithPath: "/w"))
        let session = ChatSession(projectId: project.id, title: "S")
        let projectData = try JSONEncoder().encode(project)
        let sessionData = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(Project.self, from: projectData) == project)
        #expect(try JSONDecoder().decode(ChatSession.self, from: sessionData) == session)
    }

    @Test("Legacy project records decode their folderURL into a location")
    func legacyProjectDecoding() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","serverId":"local","name":"Legacy",
         "folderURL":"file:///Users/me/src/legacy/","isArchived":false,
         "symbolName":"folder","origin":"codevisor","createdAt":768000000}
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.locations.count == 1)
        #expect(project.locations.first?.serverId == "local")
        #expect(project.locations.first?.folderPath == "/Users/me/src/legacy")
        #expect(project.folderURL.path == "/Users/me/src/legacy")
    }

    @Test("Legacy sessions decode workspaceId as projectId")
    func legacySessionDecoding() throws {
        let sessionId = UUID()
        let projectId = UUID()
        let json = """
        {"id":"\(sessionId.uuidString)","workspaceId":"\(projectId.uuidString)",
         "title":"Legacy","createdAt":768000000}
        """
        let session = try JSONDecoder().decode(ChatSession.self, from: Data(json.utf8))
        #expect(session.projectId == projectId)
        #expect(session.worktreeName == nil)
        #expect(session.cwd == nil)
    }

    @Test("Pre-rename origins decode as Codevisor")
    func legacyOriginDecoding() throws {
        let origin = try JSONDecoder().decode(SessionOrigin.self, from: Data(#""herdman""#.utf8))
        #expect(origin == .codevisor)
        #expect(String(data: try JSONEncoder().encode(origin), encoding: .utf8) == #""codevisor""#)
    }

    @Test("Worktree sessions round-trip their worktree name and cwd")
    func worktreeSessionCodable() throws {
        let session = ChatSession(
            projectId: UUID(),
            harnessId: "codex",
            worktreeName: "fix-auth",
            cwd: "/Users/me/codevisor/p/fix-auth"
        )
        let decoded = try JSONDecoder().decode(
            ChatSession.self,
            from: JSONEncoder().encode(session)
        )
        #expect(decoded.worktreeName == "fix-auth")
        #expect(decoded.cwd == "/Users/me/codevisor/p/fix-auth")
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
