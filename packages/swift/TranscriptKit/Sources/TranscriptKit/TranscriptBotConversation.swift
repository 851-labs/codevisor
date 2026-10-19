import ACPKit
import Foundation

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

  public init(id: String, sender: Sender, text: String, attachments: [Attachment] = [], sentAt: Date? = nil) {
    self.id = id
    self.sender = sender
    self.text = text
    self.attachments = attachments
    self.sentAt = sentAt
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
