import Foundation

public struct UserMessageSender: Equatable, Hashable, Sendable {
  public let agentId: String
  public let machineId: String?

  public init(agentId: String, machineId: String?) {
    self.agentId = agentId
    self.machineId = machineId
  }
}
