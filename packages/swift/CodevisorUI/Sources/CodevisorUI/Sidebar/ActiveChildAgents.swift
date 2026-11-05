public enum ChildAgentActivity: Equatable, Sendable {
  case waitingForUser
  case working
  case idle

  public init(isWaitingOnUser: Bool, isWorking: Bool) {
    if isWaitingOnUser {
      self = .waitingForUser
    } else if isWorking {
      self = .working
    } else {
      self = .idle
    }
  }
}

public enum ActiveChildAgents {
  public static func select<Agent>(_ agents: [Agent], activity: (Agent) -> ChildAgentActivity) -> [Agent] {
    let activities = agents.map { (agent: $0, activity: activity($0)) }
    let waiting = activities.filter { $0.activity == .waitingForUser }
    let working = activities.filter { $0.activity == .working }
    return (waiting + working).map(\.agent)
  }
}

public struct ChildAgentsOverflow<Agent> {
  public let shown: [Agent]
  public let hiddenCount: Int

  public init(_ agents: [Agent], limit: Int) {
    shown = Array(agents.prefix(limit))
    hiddenCount = agents.count - shown.count
  }
}
