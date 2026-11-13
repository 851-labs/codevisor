import Foundation

public struct ServerThreadParticipant: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case bot
    case agent
  }

  public var kind: Kind
  public var name: String
  public var agentId: String
  public var botId: String?
  public var machineId: String?

  public init(kind: Kind, name: String, agentId: String, botId: String? = nil, machineId: String? = nil) {
    self.kind = kind
    self.name = name
    self.agentId = agentId
    self.botId = botId
    self.machineId = machineId
  }
}

public struct ServerThreadMessage: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: String
  public var threadId: String
  public var sequence: Int
  public var from: ServerThreadParticipant
  public var text: String
  public var createdAt: String

  public init(
    id: String, threadId: String, sequence: Int, from: ServerThreadParticipant, text: String, createdAt: String
  ) {
    self.id = id
    self.threadId = threadId
    self.sequence = sequence
    self.from = from
    self.text = text
    self.createdAt = createdAt
  }
}

public struct ServerThread: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var threadId: String
  public var participants: [ServerThreadParticipant]
  public var lastMessage: ServerThreadMessage?

  public var id: String { threadId }

  public init(threadId: String, participants: [ServerThreadParticipant], lastMessage: ServerThreadMessage? = nil) {
    self.threadId = threadId
    self.participants = participants
    self.lastMessage = lastMessage
  }
}

public struct ServerThreadMessagePage: Codable, Equatable, Sendable {
  public var messages: [ServerThreadMessage]
  public var hasMore: Bool

  public init(messages: [ServerThreadMessage], hasMore: Bool) {
    self.messages = messages
    self.hasMore = hasMore
  }
}

public struct ServerThreadMessageEvent: Codable, Equatable, Sendable {
  public var message: ServerThreadMessage

  public init(message: ServerThreadMessage) {
    self.message = message
  }
}
