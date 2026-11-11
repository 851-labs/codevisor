public struct ChildAgentsSummary: Equatable, Sendable {
  public let count: Int
  public let workingCount: Int
  public let sharedHarnessId: String?

  public init?<Agent>(
    _ agents: [Agent], isWorking: (Agent) -> Bool, harnessId: (Agent) -> String?
  ) {
    guard !agents.isEmpty else { return nil }

    count = agents.count
    workingCount = agents.count(where: isWorking)
    sharedHarnessId = Self.sharedHarnessId(Set(agents.map(harnessId)))
  }

  public var isWorking: Bool {
    workingCount > 0
  }

  public var title: String {
    count == 1 ? "1 Agent" : "\(count) Agents"
  }

  private static func sharedHarnessId(_ harnessIds: Set<String?>) -> String? {
    guard harnessIds.count == 1 else { return nil }
    return harnessIds.first ?? nil
  }
}
