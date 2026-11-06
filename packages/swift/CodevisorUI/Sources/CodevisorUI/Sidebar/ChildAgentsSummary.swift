public struct ChildAgentsSummary: Equatable, Sendable {
  public let workingCount: Int

  public init?<Agent>(_ agents: [Agent], isWorking: (Agent) -> Bool) {
    let workingCount = agents.count(where: isWorking)
    guard workingCount > 0 else { return nil }

    self.workingCount = workingCount
  }

  public var title: String {
    workingCount == 1 ? "1 Agent" : "\(workingCount) Agents"
  }
}
