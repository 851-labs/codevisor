public struct BotMascotActivity: Equatable, Sendable {
  public let isInTurn: Bool
  public let isTalkingToAgent: Bool
  public let hasWorkingAgents: Bool
  public let hasAgentsWaitingOnYou: Bool
  public let hasMessages: Bool

  public init(
    isInTurn: Bool, isTalkingToAgent: Bool, hasWorkingAgents: Bool, hasAgentsWaitingOnYou: Bool, hasMessages: Bool
  ) {
    self.isInTurn = isInTurn
    self.isTalkingToAgent = isTalkingToAgent
    self.hasWorkingAgents = hasWorkingAgents
    self.hasAgentsWaitingOnYou = hasAgentsWaitingOnYou
    self.hasMessages = hasMessages
  }

  public static let resting = BotMascotActivity(
    isInTurn: false, isTalkingToAgent: false, hasWorkingAgents: false, hasAgentsWaitingOnYou: false, hasMessages: true)

  var staysAwake: Bool {
    hasAgentsWaitingOnYou || !hasMessages
  }
}
