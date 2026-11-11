import Foundation

public struct AgentReference: Sendable, Hashable {
  public var agentId: UUID
  public var machineId: String

  public init(agentId: UUID, machineId: String) {
    self.agentId = agentId
    self.machineId = machineId
  }

  public init?(agentId: String?, machineId: String?) {
    guard let agentId = agentId.flatMap(UUID.init(uuidString:)), let machineId else { return nil }
    self.init(agentId: agentId, machineId: machineId)
  }
}
