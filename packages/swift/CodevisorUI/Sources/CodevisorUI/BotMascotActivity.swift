public struct BotMascotActivity: Equatable, Sendable {
  public let isInTurn: Bool
  public let isTalkingToAgent: Bool
  public let hasActiveAgents: Bool

  public init(isInTurn: Bool, isTalkingToAgent: Bool, hasActiveAgents: Bool) {
    self.isInTurn = isInTurn
    self.isTalkingToAgent = isTalkingToAgent
    self.hasActiveAgents = hasActiveAgents
  }

  public static let resting = BotMascotActivity(isInTurn: false, isTalkingToAgent: false, hasActiveAgents: false)
}
