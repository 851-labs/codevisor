public struct BotMascotActivity: Equatable, Sendable {
  public let isInTurn: Bool
  public let isTalkingToAgent: Bool
  public let hasActiveAgents: Bool
  public let hasMessages: Bool

  public init(isInTurn: Bool, isTalkingToAgent: Bool, hasActiveAgents: Bool, hasMessages: Bool) {
    self.isInTurn = isInTurn
    self.isTalkingToAgent = isTalkingToAgent
    self.hasActiveAgents = hasActiveAgents
    self.hasMessages = hasMessages
  }

  public static let resting = BotMascotActivity(
    isInTurn: false, isTalkingToAgent: false, hasActiveAgents: false, hasMessages: true)

  var staysAwake: Bool {
    hasActiveAgents || !hasMessages
  }
}
