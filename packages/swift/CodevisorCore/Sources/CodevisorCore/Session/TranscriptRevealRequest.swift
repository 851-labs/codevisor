import Foundation

public struct TranscriptRevealRequest: Equatable, Sendable {
  public let id = UUID()
  public let toolCallId: String

  public init(toolCallId: String) {
    self.toolCallId = toolCallId
  }
}
