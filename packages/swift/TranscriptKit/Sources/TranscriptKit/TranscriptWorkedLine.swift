import ACPKit
import Foundation

public struct TranscriptWorkedLine: Sendable, Equatable {
  public enum Content: Sendable, Equatable {
    case item(WorkedItem)
    case thinking
    case earlierHistory(count: Int)
  }

  public let reference: TranscriptWorkedItemReference
  public let content: Content
  public let isFirst: Bool
  public let isLast: Bool
  public let isTurnActive: Bool
  public let awaitedAgents: [ToolCall]

  public init(
    reference: TranscriptWorkedItemReference,
    content: Content,
    isFirst: Bool,
    isLast: Bool,
    isTurnActive: Bool,
    awaitedAgents: [ToolCall] = []
  ) {
    self.reference = reference
    self.content = content
    self.isFirst = isFirst
    self.isLast = isLast
    self.isTurnActive = isTurnActive
    self.awaitedAgents = awaitedAgents
  }
}
