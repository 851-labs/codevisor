import Foundation

public struct TranscriptEventMarker: Sendable, Equatable {
  public let messageID: UUID
  public let events: [TranscriptEvent]

  public init?(message: UserMessage) {
    guard let events = Self.events(of: message) else { return nil }

    self.messageID = message.id
    self.events = events
  }

  private static func events(of message: UserMessage) -> [TranscriptEvent]? {
    if message.isEvent { return TranscriptEventParser.events(in: message.text) }
    guard let sender = message.sentByAgentId else { return nil }

    return [agentMessage(message, from: sender)]
  }

  private static func agentMessage(_ message: UserMessage, from sender: String) -> TranscriptEvent {
    var attributes = ["from": sender]
    attributes["fromMachineId"] = message.sentByAgentMachineId
    return TranscriptEvent(type: TranscriptEvent.agentMessageType, attributes: attributes, body: message.text)
  }
}
