import CodevisorClient

public struct PromptAcceptance: Sendable, Equatable {
  public enum Delivery: String, Sendable {
    case newTurn = "new_turn"
    case steer
    case queue
    case bot
  }

  public enum Outcome: String, Sendable {
    case startedTurn = "started_turn"
    case steered
    case queued
    case delivered
  }

  public let attachmentCount: Int
  public let delivery: Delivery
  public let outcome: Outcome

  public init(attachmentCount: Int, delivery: Delivery, outcome: Outcome) {
    self.attachmentCount = attachmentCount
    self.delivery = delivery
    self.outcome = outcome
  }

  public var isQueued: Bool { outcome == .queued }

  static func outgoing(
    attachmentCount: Int,
    requested: ServerPromptDelivery?,
    wasSteered: Bool?
  ) -> PromptAcceptance {
    switch requested {
    case .steer:
      PromptAcceptance(
        attachmentCount: attachmentCount, delivery: .steer, outcome: wasSteered == false ? .queued : .steered)
    case .queue:
      PromptAcceptance(attachmentCount: attachmentCount, delivery: .queue, outcome: .queued)
    case nil:
      PromptAcceptance(attachmentCount: attachmentCount, delivery: .bot, outcome: .delivered)
    }
  }
}
