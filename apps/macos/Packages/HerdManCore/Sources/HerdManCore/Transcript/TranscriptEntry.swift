import Foundation
import ACPKit

/// A single ordered element of an assistant turn: either a streamed text span
/// or a tool call. Preserving the order of these entries is what lets the UI
/// render text → tool → tool → text → tool → text exactly as it streamed.
public enum TranscriptEntry: Identifiable, Sendable, Equatable {
    case text(id: String, markdown: String)
    case tool(ToolCall)

    public var id: String {
        switch self {
        case let .text(id, _): return "text:\(id)"
        case let .tool(call): return "tool:\(call.toolCallId)"
        }
    }

    public var isText: Bool {
        if case .text = self { return true }
        return false
    }
}

/// The streaming state of one assistant response.
public struct AssistantTurn: Sendable, Equatable {
    public var entries: [TranscriptEntry]
    public var isGenerating: Bool
    public var isThinking: Bool
    public var stopReason: StopReason?
    public var plan: Plan?
    public var startedAt: Date?
    public var endedAt: Date?
    /// Monotonic counter used to give each new text span a stable id.
    var nextTextId: Int

    public init(
        entries: [TranscriptEntry] = [],
        isGenerating: Bool = false,
        isThinking: Bool = false,
        stopReason: StopReason? = nil,
        plan: Plan? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        nextTextId: Int = 0
    ) {
        self.entries = entries
        self.isGenerating = isGenerating
        self.isThinking = isThinking
        self.stopReason = stopReason
        self.plan = plan
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.nextTextId = nextTextId
    }
}

public extension AssistantTurn {
    /// The trailing text span, rendered expanded at the bottom as the final answer.
    var finalText: TranscriptEntry? {
        guard let last = entries.last, last.isText else { return nil }
        return last
    }

    /// Everything before the final answer — intermediate text and all tool
    /// calls — collapsed into the "Worked for…" disclosure.
    var workedEntries: [TranscriptEntry] {
        finalText == nil ? entries : Array(entries.dropLast())
    }

    var hasWorkedContent: Bool { !workedEntries.isEmpty }

    /// The tool calls within this turn, in order.
    var toolCalls: [ToolCall] {
        entries.compactMap { if case let .tool(call) = $0 { return call } else { return nil } }
    }

    /// Wall-clock duration of the turn, once finished.
    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

/// A user-authored prompt in the conversation.
public struct UserMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// An assistant response in the conversation, with stable identity for the UI.
public struct AssistantMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var turn: AssistantTurn

    public init(id: UUID = UUID(), turn: AssistantTurn) {
        self.id = id
        self.turn = turn
    }
}

/// One item in the rendered conversation.
public enum ConversationItem: Identifiable, Sendable, Equatable {
    case user(UserMessage)
    case assistant(AssistantMessage)

    public var id: UUID {
        switch self {
        case let .user(message): return message.id
        case let .assistant(message): return message.id
        }
    }
}
