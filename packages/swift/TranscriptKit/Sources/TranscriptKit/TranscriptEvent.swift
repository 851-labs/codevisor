import Foundation

public struct TranscriptEvent: Sendable, Equatable {
  public static let agentMessageType = "session.message"
  public static let threadMessageType = "thread.message"

  public let type: String
  public let attributes: [String: String]
  public let body: String

  public init(type: String, attributes: [String: String] = [:], body: String) {
    self.type = type
    self.attributes = attributes
    self.body = body
  }

  public subscript(attribute name: String) -> String? {
    attributes[name]
  }

  public var threadID: String? {
    type == Self.threadMessageType ? self[attribute: "threadId"] : nil
  }
}
