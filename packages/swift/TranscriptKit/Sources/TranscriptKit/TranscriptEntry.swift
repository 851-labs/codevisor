import Foundation
import ACPKit

/// A single ordered element of an assistant turn. Preserving the order of
/// these entries is what lets the UI render text, tools, and lifecycle events
/// exactly where they occurred.
public enum TranscriptEntry: Identifiable, Sendable, Equatable {
  case text(id: String, markdown: String)
  case tool(ToolCall)
  case contextCompaction(id: String, status: ContextCompactionStatus)

  public var id: String {
    switch self {
    case let .text(id, _): return "text:\(id)"
    case let .tool(call): return "tool:\(call.toolCallId)"
    case let .contextCompaction(id, _): return "compaction:\(id)"
    }
  }

  /// A text span carrying nothing a reader can see — empty, or whitespace
  /// only. Harnesses legitimately stream these (Claude retro-tags a preamble
  /// with a zero-length chunk, and a message can open with a bare newline),
  /// so they reach the transcript as ordinary spans. They must never count
  /// as content: doing so retires the activity indicator and hands the UI a
  /// "final answer" that renders nothing, leaving reserved blank space where
  /// the shimmer belongs.
  var isBlankText: Bool {
    guard case let .text(_, markdown) = self else { return false }
    return markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// A user-authored prompt in the conversation.
public struct UserMessage: Identifiable, Sendable, Equatable {
  public let id: UUID
  public var text: String
  public var attachments: [Attachment]
  public var textResource: ToolDetailResource?

  public init(id: UUID = UUID(), text: String, attachments: [Attachment] = [], textResource: ToolDetailResource? = nil)
  {
    self.id = id
    self.text = text
    self.textResource = textResource
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

  /// Whether this item has a presentation in the chat transcript.
  ///
  /// Canonical history may contain completed structural shells for turns
  /// where the harness emitted no message or assistant output. Keeping those
  /// shells in the display model creates empty virtual rows whose estimated
  /// heights can never be replaced by a real measurement.
  public var hasRenderableTranscriptContent: Bool {
    switch self {
    case let .user(message):
      return !message.text.isEmpty || !message.attachments.isEmpty
    case let .assistant(message):
      let turn = message.turn
      return turn.isGenerating
        || turn.entries.contains { entry in
          if case .contextCompaction = entry { return false }
          return true
        }
        || !turn.attachments.isEmpty
        || turn.hasDeferredWorkedDetails
        || !(turn.planDocument?.isEmpty ?? true)
        || !(turn.stopDetail?.isEmpty ?? true)
    }
  }
}
