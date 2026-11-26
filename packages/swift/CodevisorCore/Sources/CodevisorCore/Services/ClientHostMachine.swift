import Foundation

public struct ClientHostMachine: Codable, Equatable, Sendable {
  public let machineId: String
  public let name: String

  public init(machineId: String, name: String) {
    self.machineId = machineId
    self.name = name
  }
}
