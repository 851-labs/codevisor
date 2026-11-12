import Foundation

public struct TranscriptEvent: Sendable, Equatable {
  public static let agentMessageType = "session.message"

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
}
