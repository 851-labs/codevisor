import Foundation

public enum ServerBotMessageSender: String, Codable, Equatable, Hashable, Sendable {
  case user
  case bot
  case notice
}

public struct ServerBotMessage: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var sessionId: String
  public var sequence: Int
  public var sender: ServerBotMessageSender
  public var text: String
  public var attachments: [ServerAttachmentRef]?
  public var createdAt: String

  public init(
    id: String,
    sessionId: String,
    sequence: Int,
    sender: ServerBotMessageSender,
    text: String,
    attachments: [ServerAttachmentRef]? = nil,
    createdAt: String
  ) {
    self.id = id
    self.sessionId = sessionId
    self.sequence = sequence
    self.sender = sender
    self.text = text
    self.attachments = attachments
    self.createdAt = createdAt
  }
}

public struct ServerBotConversationPage: Codable, Equatable, Sendable {
  public var messages: [ServerBotMessage]
  public var hasMore: Bool
  public var working: Bool

  public init(messages: [ServerBotMessage], hasMore: Bool, working: Bool) {
    self.messages = messages
    self.hasMore = hasMore
    self.working = working
  }
}
