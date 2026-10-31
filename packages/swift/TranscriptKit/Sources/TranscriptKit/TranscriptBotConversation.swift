import ACPKit
import Foundation

public enum TranscriptDelivery: Equatable, Sendable {
  case sending
  case failed(reason: String?)

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
    delivery: TranscriptDelivery?, files: [PreviewFile], isTranscriptMarkdown: Bool
  ) {
    self.id = id
    self.sender = sender
    self.text = text
    self.attachments = attachments
    self.sentAt = sentAt
    self.delivery = delivery
    self.files = files
    self.isTranscriptMarkdown = isTranscriptMarkdown
  }
}

public struct TranscriptBotConversation: Equatable, Sendable {
  public let messages: [TranscriptBotMessage]
  public let isWorking: Bool

  public init(messages: [TranscriptBotMessage], isWorking: Bool) {
    self.messages = messages
    self.isWorking = isWorking
  }
}
