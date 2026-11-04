import ACPKit
import Foundation

public enum TranscriptDelivery: Equatable, Sendable {
  case sending
  case failed(reason: String?)
  case awaitingStep

  public var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}

public struct TranscriptBotMessage: Identifiable, Equatable, Sendable {
  public enum Sender: Equatable, Sendable {
    case user
    case bot
    case notice
  }

  public let id: String
  public let sender: Sender
  public let text: String
  public let attachments: [Attachment]
  public let sentAt: Date?
  public let delivery: TranscriptDelivery?
  public let files: [PreviewFile]
  public let isTranscriptMarkdown: Bool
  public let app: CodevisorExecutionApp?

  public init(
    id: String, sender: Sender, text: String, attachments: [Attachment] = [], sentAt: Date? = nil,
    delivery: TranscriptDelivery? = nil
  ) {
    self.init(
      id: id, sender: sender, text: text, attachments: attachments, sentAt: sentAt, delivery: delivery, files: [],
      isTranscriptMarkdown: false)
  }

  init(
    id: String, sender: Sender, text: String, attachments: [Attachment], sentAt: Date?,
    delivery: TranscriptDelivery?, files: [PreviewFile], isTranscriptMarkdown: Bool, app: CodevisorExecutionApp? = nil
  ) {
    self.id = id
    self.sender = sender
    self.text = text
    self.attachments = attachments
    self.sentAt = sentAt
    self.delivery = delivery
    self.files = files
    self.isTranscriptMarkdown = isTranscriptMarkdown
    self.app = app
  }
}

public struct TranscriptBotConversation: Equatable, Sendable {
  public let messages: [TranscriptBotMessage]
  public let isWorking: Bool

  public init(messages: [TranscriptBotMessage], isWorking: Bool) {
    self.messages = messages
    self.isWorking = isWorking
  }

  func merging(_ parts: [TranscriptBotMessage]) -> TranscriptBotConversation {
    guard !parts.isEmpty else { return self }

    var merged = messages
    for part in parts {
      let index = merged.firstIndex { Self.isAfter($0, part) } ?? merged.endIndex
      merged.insert(part, at: index)
    }
    return TranscriptBotConversation(messages: merged, isWorking: isWorking)
  }

  private static func isAfter(_ message: TranscriptBotMessage, _ part: TranscriptBotMessage) -> Bool {
    guard let sent = message.sentAt, let partSent = part.sentAt else { return false }
    return sent > partSent
  }
}
