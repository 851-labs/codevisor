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

  public enum Side: Equatable, Sendable {
    case leading
    case trailing
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
  public let side: Side

  public init(
    id: String, sender: Sender, text: String, attachments: [Attachment] = [], sentAt: Date? = nil,
    delivery: TranscriptDelivery? = nil, side: Side = .leading
  ) {
    self.init(
      id: id, sender: sender, text: text, attachments: attachments, sentAt: sentAt, delivery: delivery, files: [],
      isTranscriptMarkdown: false, side: side)
  }

  init(
    id: String, sender: Sender, text: String, attachments: [Attachment], sentAt: Date?,
    delivery: TranscriptDelivery?, files: [PreviewFile], isTranscriptMarkdown: Bool, app: CodevisorExecutionApp? = nil,
    side: Side = .leading
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
    self.side = side
  }

  public func withDelivery(_ delivery: TranscriptDelivery?) -> TranscriptBotMessage {
    TranscriptBotMessage(
      id: id, sender: sender, text: text, attachments: attachments, sentAt: sentAt, delivery: delivery, files: files,
      isTranscriptMarkdown: isTranscriptMarkdown, app: app, side: side)
  }
}

public struct TranscriptBotConversation: Equatable, Sendable {
  public let messages: [TranscriptBotMessage]
  public let isWorking: Bool

  public init(messages: [TranscriptBotMessage], isWorking: Bool) {
    self.messages = messages
    self.isWorking = isWorking
  }

  public func mappingDeliveries(_ delivery: (TranscriptBotMessage) -> TranscriptDelivery?) -> TranscriptBotConversation
  {
    TranscriptBotConversation(messages: messages.map { $0.withDelivery(delivery($0)) }, isWorking: isWorking)
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
