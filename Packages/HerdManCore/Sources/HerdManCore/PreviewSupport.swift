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
        configOptions: [SessionConfigOption] = SampleData.configOptions
    ) -> SessionModel {
        let model = SessionModel(
            client: ACPClient(transport: MockTransport()),
            sessionId: "preview",
            modeState: modeState,
            configOptions: configOptions
        )
        model.applyPreviewState(conversation: conversation, isSending: isSending)
        return model
    }
}
