public struct BotMascotActivity: Equatable, Sendable {
  public let isWorking: Bool
  public let isWaitingOnAgents: Bool

  public init(isWorking: Bool, isWaitingOnAgents: Bool) {
    self.isWorking = isWorking
    self.isWaitingOnAgents = isWaitingOnAgents
  }

  public static let resting = BotMascotActivity(isWorking: false, isWaitingOnAgents: false)
}
