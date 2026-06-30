import Foundation
import ACPKit

/// Applies streamed `SessionUpdate`s to an `AssistantTurn`, preserving arrival
/// order and merging tool-call updates. Pure and synchronous so it is trivially
/// unit-testable; the view model wraps it with the async update stream.
public enum TranscriptReducer {
    public static func apply(_ update: SessionUpdate, to turn: inout AssistantTurn) {
        switch update {
        case let .agentMessageChunk(block):
            turn.isThinking = false
            appendText(text(from: block), to: &turn)

        case .agentThoughtChunk:
            // Thoughts surface only as the ephemeral "Thinking…" indicator; they
            // are not persisted as transcript entries.
            turn.isThinking = true

        case .userMessageChunk:
            break // Echo of the user's own input.

        case let .toolCall(call):
            turn.isThinking = false
            upsertTool(call, to: &turn)

        case let .toolCallUpdate(update):
            turn.isThinking = false
            applyToolUpdate(update, to: &turn)

        case let .plan(plan):
            turn.plan = plan

        case .availableCommandsUpdate, .currentModeUpdate, .configOptionUpdate:
            break
        }
    }

    // MARK: - Helpers

    private static func text(from block: ContentBlock) -> String {
        block.textValue ?? ""
    }

    /// Appends streamed text, extending the open text span if the last entry is
    /// text, otherwise starting a new text span after the most recent tool call.
    private static func appendText(_ newText: String, to turn: inout AssistantTurn) {
        guard !newText.isEmpty else { return }
        if case let .text(id, existing) = turn.entries.last {
            turn.entries[turn.entries.count - 1] = .text(id: id, markdown: existing + newText)
        } else {
            let id = "t\(turn.nextTextId)"
            turn.nextTextId += 1
            turn.entries.append(.text(id: id, markdown: newText))
        }
    }

    private static func toolIndex(_ toolCallId: String, in turn: AssistantTurn) -> Int? {
        turn.entries.firstIndex {
            if case let .tool(call) = $0 { return call.toolCallId == toolCallId }
            return false
        }
    }

    private static func upsertTool(_ call: ToolCall, to turn: inout AssistantTurn) {
        if let index = toolIndex(call.toolCallId, in: turn) {
            turn.entries[index] = .tool(call)
        } else {
            turn.entries.append(.tool(call))
        }
    }

    private static func applyToolUpdate(_ update: ToolCallUpdate, to turn: inout AssistantTurn) {
        if let index = toolIndex(update.toolCallId, in: turn), case let .tool(existing) = turn.entries[index] {
            turn.entries[index] = .tool(existing.applying(update))
        } else {
            turn.entries.append(.tool(update.asToolCall()))
        }
    }
}
