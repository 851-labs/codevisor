import Foundation

public struct McpFleetEntry: Identifiable, Equatable, Sendable {
  public var name: String
  public var serverByMachine: [String: ServerMcpServer]
  public var representative: ServerMcpServer
  public var id: String { name }

  public init?(
    name: String, serverByMachine: [String: ServerMcpServer], preferredMachineId: String?
  ) {
    guard let machineId = Self.machineId(in: serverByMachine, preferring: preferredMachineId),
      let representative = serverByMachine[machineId]
    else { return nil }
    self.name = name
    self.serverByMachine = serverByMachine
    self.representative = representative
  }

  public var kind: String? { representative.kind }
  public var transport: String { representative.transport }
  public var authType: String { representative.authType }
  public var canEdit: Bool { representative.canEdit != false }
  public var canRemove: Bool { representative.canRemove != false }
  public var isBuiltIn: Bool { representative.isBuiltIn }
  public var isMachineScoped: Bool { isBuiltIn }
  public var idByMachine: [String: String] { serverByMachine.mapValues(\.id) }

  public func server(on machineId: String) -> ServerMcpServer? {
    serverByMachine[machineId]
  }

  public func machineId(preferring preferred: String?) -> String? {
    Self.machineId(in: serverByMachine, preferring: preferred)
  }

  private static func machineId(
    in servers: [String: ServerMcpServer], preferring preferred: String?
  ) -> String? {
    if let preferred, servers[preferred] != nil { return preferred }
    return servers.keys.sorted().first
  }
}
