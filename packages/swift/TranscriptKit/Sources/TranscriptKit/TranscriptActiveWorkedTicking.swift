import Foundation

public struct TranscriptActiveWorkedTicking: Equatable, Sendable {
  public let messageID: UUID
  public let ticksPlanning: Bool
  public let ticksImplementation: Bool

  public init?(_ item: ConversationItem?) {
    guard case let .assistant(message)? = item else { return nil }
    messageID = message.id
    ticksPlanning = message.turn.workedSectionTicks(.planning)
    ticksImplementation = message.turn.workedSectionTicks(.implementation)
  }

  public func ticks(_ kind: TranscriptWorkedSectionKind, messageID: UUID) -> Bool? {
    guard messageID == self.messageID else { return nil }
    switch kind {
    case .planning: return ticksPlanning
    case .implementation: return ticksImplementation
    }
  }
}
