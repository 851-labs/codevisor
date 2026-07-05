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

/// The streamed thread of one subagent (text spans and tool calls), nested
/// under the parent tool call that spawned it. Same shape as a turn's entries,
/// which is what lets the UI render it with the same transcript components.
public struct SubagentTranscript: Sendable, Equatable {
    public var entries: [TranscriptEntry]
    public var isThinking: Bool
    /// Monotonic counter used to give each new text span a stable id.
    var nextTextId: Int

    public init(entries: [TranscriptEntry] = [], isThinking: Bool = false, nextTextId: Int = 0) {
        self.entries = entries
        self.isThinking = isThinking
        self.nextTextId = nextTextId
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
    /// Nested subagent threads, keyed by the parent (Task/agent) tool call id.
    /// Deliberately flat: a subagent's own agent calls key their buckets here
    /// too, so the UI recurses by lookup instead of by structure.
    public var subagents: [String: SubagentTranscript]
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
        subagents: [String: SubagentTranscript] = [:],
        nextTextId: Int = 0
    ) {
        self.entries = entries
        self.isGenerating = isGenerating
        self.isThinking = isThinking
        self.stopReason = stopReason
        self.plan = plan
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.subagents = subagents
        self.nextTextId = nextTextId
    }
}

public extension AssistantTurn {
    /// The last assistant text message, rendered expanded at the bottom as the final answer.
    ///
    /// ACP agents may interleave tool calls after chunks for the final message.
    /// Treating "physically last entry" as final hides valid answers in that shape.
    var finalText: TranscriptEntry? {
        guard let index = finalTextIndex else { return nil }
        return entries[index]
    }

    /// Everything except the final answer — intermediate text and all tool
    /// calls — collapsed into the "Worked for…" disclosure.
    var workedEntries: [TranscriptEntry] {
        guard let finalTextIndex else { return entries }
        return entries.enumerated().compactMap { offset, entry in
            offset == finalTextIndex ? nil : entry
        }
    }

    var hasWorkedContent: Bool { !workedEntries.isEmpty }

    /// The tool calls within this turn, in order.
    var toolCalls: [ToolCall] {
        entries.compactMap { if case let .tool(call) = $0 { return call } else { return nil } }
    }

    /// Every tool call in the turn, including those inside subagent threads —
    /// the membership check for routing late updates into a finished turn.
    var allToolCalls: [ToolCall] {
        toolCalls + subagents.keys.sorted().flatMap { key in
            (subagents[key]?.entries ?? []).compactMap {
                if case let .tool(call) = $0 { return call } else { return nil }
            }
        }
    }

    /// Cheap change signal for streaming subagent activity, folded into the
    /// scroll-follow fingerprint so nested output keeps the view pinned.
    var subagentActivityFingerprint: Int {
        var hasher = Hasher()
        for key in subagents.keys.sorted() {
            guard let bucket = subagents[key] else { continue }
            hasher.combine(key)
            hasher.combine(bucket.entries.count)
            hasher.combine(bucket.isThinking)
            if case let .text(_, markdown) = bucket.entries.last {
                hasher.combine(markdown.count)
            }
        }
        return hasher.finalize()
    }

    /// Wall-clock duration of the turn, once finished.
    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    private var finalTextIndex: Int? {
        entries.indices.reversed().first { entries[$0].isText }
    }
}

/// A file attached to a user message, referencing bytes stored server-side
/// (`GET /v1/files/:id`).
public struct Attachment: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case image
        case file
    }

    public let fileId: String
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var kind: Kind

    public var id: String { fileId }

    public init(fileId: String, name: String, mimeType: String, sizeBytes: Int, kind: Kind) {
        self.fileId = fileId
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.kind = kind
    }
}

/// A user-authored prompt in the conversation.
public struct UserMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public var attachments: [Attachment]

    public init(id: UUID = UUID(), text: String, attachments: [Attachment] = []) {
        self.id = id
        self.text = text
        self.attachments = attachments
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
