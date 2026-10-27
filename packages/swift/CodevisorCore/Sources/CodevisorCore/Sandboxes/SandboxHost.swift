import Foundation

public struct SandboxHost: Equatable, Identifiable, Sendable {
  public let serverId: String
  public let name: String
  public let capabilities: Set<String>

  public var id: String { serverId }

  public init(serverId: String, name: String, capabilities: Set<String>) {
    self.serverId = serverId
    self.name = name
    self.capabilities = capabilities
  }
}
