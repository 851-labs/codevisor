import Foundation
import ACPKit

/// Sample data and preview factories for SwiftUI previews in the app target.
public enum SampleData {
    /// A representative conversation: a user prompt and a completed assistant
    /// turn with intermediate text, two tool calls, and a final markdown answer.
    public static var conversation: [ConversationItem] {
        var turn = AssistantTurn(
            isGenerating: false,
            stopReason: .endTurn,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 14)
        )
        TranscriptReducer.apply(.agentMessageChunk(.text("I'll ground this in the current checkout first.")), to: &turn)
        TranscriptReducer.apply(.toolCall(ToolCall(
            toolCallId: "exec-1",
            title: "Ran rg -n \"actor|connection\" Sources",
            kind: .execute,
            status: .completed,
            content: [.content(.text("$ rg -n \"actor\"\nSources/ACPKit/Client/ACPConnection.swift:14"))]
        )), to: &turn)
        TranscriptReducer.apply(.toolCall(ToolCall(
            toolCallId: "search-1", title: "Searched for files", kind: .search, status: .completed
        )), to: &turn)
        TranscriptReducer.apply(.agentMessageChunk(.text("The README matches the layout. Reading the entrypoints now.")), to: &turn)
        TranscriptReducer.apply(.toolCall(ToolCall(
            toolCallId: "read-1", title: "Read Package.swift", kind: .read, status: .completed,
            content: [.content(.text("// swift-tools-version: 6.0"))]
        )), to: &turn)
        TranscriptReducer.apply(.toolCall(ToolCall(
            toolCallId: "read-2", title: "Read ACPConnection.swift", kind: .read, status: .completed
        )), to: &turn)
        TranscriptReducer.apply(.toolCall(ToolCall(
            toolCallId: "read-3", title: "Read ACPClient.swift", kind: .read, status: .completed
        )), to: &turn)
        TranscriptReducer.apply(.agentMessageChunk(.text("""
        Here's what I found:

        - The package targets **macOS 26**
        - It uses an `actor` for the connection

        ```swift
        public actor ACPConnection {
            // ...
        }
        ```
        """)), to: &turn)

        return [
            .user(UserMessage(text: "How is the ACP connection implemented?")),
            .assistant(AssistantMessage(turn: turn))
        ]
    }

    /// Sample model and reasoning config options for composer previews.
    public static var configOptions: [SessionConfigOption] {
        [
            SessionConfigOption(
                id: "model", name: "Model", category: "model", currentValue: "gpt-5.5",
                options: [
                    SessionConfigSelectOption(value: "gpt-5.5", name: "GPT-5.5"),
                    SessionConfigSelectOption(value: "gpt-5.4", name: "GPT-5.4"),
                    SessionConfigSelectOption(value: "gpt-5.4-mini", name: "GPT-5.4-Mini")
                ]
            ),
            SessionConfigOption(
                id: "reasoning_effort", name: "Reasoning effort", category: "thought_level", currentValue: "high",
                options: [
                    SessionConfigSelectOption(value: "low", name: "Low"),
                    SessionConfigSelectOption(value: "medium", name: "Medium"),
                    SessionConfigSelectOption(value: "high", name: "High")
                ]
            )
        ]
    }

    /// A turn mid-stream, showing the "Thinking…" state.
    public static var streamingConversation: [ConversationItem] {
        var turn = AssistantTurn(isGenerating: true, isThinking: true, startedAt: Date(timeIntervalSince1970: 0))
        TranscriptReducer.apply(.toolCall(ToolCall(
            toolCallId: "t1", title: "Running tests", kind: .execute, status: .inProgress
        )), to: &turn)
        return [
            .user(UserMessage(text: "Run the test suite")),
            .assistant(AssistantMessage(turn: turn))
        ]
    }
}

public extension SessionModel {
    /// Builds a `SessionModel` pre-seeded with a conversation for previews.
    @MainActor
    static func preview(
        conversation: [ConversationItem] = SampleData.conversation,
        isSending: Bool = false,
        modeState: SessionModeState? = SessionModeState(
            currentModeId: "default",
            availableModes: [SessionMode(id: "default", name: "Default"), SessionMode(id: "plan", name: "Plan")]
        ),
        configOptions: [SessionConfigOption] = SampleData.configOptions,
        usage: SessionUsage? = SessionUsage(used: 18_432, size: 200_000, cost: SessionCost(amount: 0.0142, currency: "USD"))
    ) -> SessionModel {
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: PreviewServerClient(), sessionId: UUID()),
            sessionId: "preview",
            modeState: modeState,
            configOptions: configOptions
        )
        model.applyPreviewState(conversation: conversation, isSending: isSending, usage: usage)
        return model
    }
}

/// A no-op server client for previews and preview-backed tests: the event
/// stream never yields and every write throws or drops, so nothing can reach
/// a real server.
struct PreviewServerClient: HerdManServerClienting {
    func health() async throws -> ServerHealth {
        ServerHealth(ok: true, version: "0.0.0", database: "ready")
    }

    func info() async throws -> ServerInfo { throw HerdManServerClientError.invalidResponse }
    func updateInfo() async throws -> ServerUpdateInfo { throw HerdManServerClientError.invalidResponse }
    func issuePairingToken() async throws -> ServerPairingToken { throw HerdManServerClientError.invalidResponse }
    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
    func listHarnesses() async throws -> [ServerHarness] { [] }
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness {
        throw HerdManServerClientError.invalidResponse
    }
    func listProjects() async throws -> [ServerProject] { [] }
    func upsertProject(_ project: Project) async throws -> ServerProject {
        throw HerdManServerClientError.invalidResponse
    }
    func updateProject(_ project: Project) async throws -> ServerProject {
        throw HerdManServerClientError.invalidResponse
    }
    func deleteProject(id: UUID) async throws {}
    func listSessions() async throws -> [ServerSession] { [] }
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail {
        throw HerdManServerClientError.invalidResponse
    }
    func upsertSession(_ session: ChatSession) async throws -> ServerSession {
        throw HerdManServerClientError.invalidResponse
    }
    func updateSession(_ session: ChatSession) async throws -> ServerSession {
        throw HerdManServerClientError.invalidResponse
    }
    func deleteSession(id: UUID) async throws {}
    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
    }
    func cancelSession(id: UUID) async throws {}
    func setSessionMode(id: UUID, modeId: String) async throws {}
    func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { _ in }
    }
}
