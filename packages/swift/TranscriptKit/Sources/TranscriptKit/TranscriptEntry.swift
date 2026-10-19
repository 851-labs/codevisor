import Foundation
import ACPKit

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

  var isBlankText: Bool {
    guard case let .text(_, markdown) = self else { return false }
    return markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

public struct UserMessage: Identifiable, Sendable, Equatable {
  public let id: UUID
  public var text: String
  public var attachments: [Attachment]
  public var textResource: ToolDetailResource?
  public var isEvent: Bool

  public init(
    id: UUID = UUID(),
    text: String,
    attachments: [Attachment] = [],
    textResource: ToolDetailResource? = nil,
    isEvent: Bool = false
  ) {
    self.id = id
    self.text = text
    self.textResource = textResource
    self.attachments = attachments
    self.isEvent = isEvent
  }
}

public struct AssistantMessage: Identifiable, Sendable, Equatable {
  public let id: UUID
  public var turn: AssistantTurn

  public init(id: UUID = UUID(), turn: AssistantTurn) {
    self.id = id
    self.turn = turn
  }
}

public enum ConversationItem: Identifiable, Sendable, Equatable {
  case user(UserMessage)
  case assistant(AssistantMessage)

  public var id: UUID {
    switch self {
    case let .user(message): return message.id
    case let .assistant(message): return message.id
    }
  }

  public var isVisibleInTranscript: Bool {
    guard case let .user(message) = self else { return true }
    return !message.isEvent
  }

  public var userPrompt: UserMessage? {
    guard case let .user(message) = self, !message.isEvent else { return nil }
    return message
  }

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
