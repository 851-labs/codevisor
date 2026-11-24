import CodevisorCore
import Foundation

public enum PluginSignInRoute {
  case machine(id: String, client: any CodevisorServerClienting)
  case thisMac(any CodevisorServerClienting)
  case unavailable(machineName: String)

  @MainActor
  public static func resolve(on machineId: String, machines: MachineController) -> PluginSignInRoute {
    resolve(
      on: machineId,
      statusByMachineId: machines.statusByMachineId,
      machineName: machines.machine(for: machineId)?.name ?? machines.statusByMachineId[machineId]?.label,
      hasThisMac: CodevisorServerClient.hostsServers && machines.allMachines.contains(where: \.isLocal),
      client: machines.client(for:)
    )
  }

  static func resolve(
    on machineId: String,
    statusByMachineId: [String: MachineStatus],
    machineName: String?,
    hasThisMac: Bool,
    client: (String) -> any CodevisorServerClienting
  ) -> PluginSignInRoute {
    let isThisMac = hasThisMac && codevisorMachineIsThisMac(machineId, statusByMachineId: statusByMachineId)
    if isThisMac || relaysThroughCloud(machineId, statusByMachineId: statusByMachineId) {
      return .machine(id: machineId, client: client(machineId))
    }
    guard hasThisMac else { return .unavailable(machineName: machineName ?? "That machine") }

    return .thisMac(client(CodevisorMachine.local.id))
  }

  public var client: (any CodevisorServerClienting)? {
    switch self {
    case let .machine(_, client), let .thisMac(client): client
    case .unavailable: nil
    }
  }

  public func unavailableMessage(plugin: String) -> String? {
    guard case let .unavailable(machineName) = self else { return nil }
    return PluginSignInError.offCloud(machine: machineName, plugin: plugin).errorDescription
  }

  @MainActor
  public func openBrowser(for server: ServerMcpServer, presenter: any WebSignInPresenting) throws -> PluginSignInBrowser
  {
    guard let client else { throw unavailableError(plugin: server.name) }
    return PluginSignInBrowser(client: client, pluginName: server.name, presenter: presenter)
  }

  @MainActor
  public func start(_ server: ServerMcpServer, ticket: String?) async throws -> PluginSignInStart {
    try await ServerConnectionLoss.retryingInterruptions(sleep: { try await Task.sleep(for: $0) }) {
      try await startOnce(server, ticket: ticket)
    }
  }

  @MainActor
  private func startOnce(_ server: ServerMcpServer, ticket: String?) async throws -> PluginSignInStart {
    switch self {
    case let .machine(id, client):
      let started = try await client.startMcpOAuth(id: server.id, ticket: ticket)
      return PluginSignInStart(authorizationUrl: started.authorizationUrl, serverId: server.id, machineId: id)
    case let .thisMac(local):
      let copy = try await Self.thisMacCopy(of: server, on: local)
      let started = try await local.startMcpOAuth(id: copy.id, ticket: ticket)
      return PluginSignInStart(
        authorizationUrl: started.authorizationUrl, serverId: copy.id, machineId: CodevisorMachine.local.id)
    case .unavailable:
      throw unavailableError(plugin: server.name)
    }
  }

  private func unavailableError(plugin: String) -> PluginSignInError {
    guard case let .unavailable(machineName) = self else { return .notOnThisMac(plugin: plugin) }
    return .offCloud(machine: machineName, plugin: plugin)
  }

  @MainActor
  private static func thisMacCopy(
    of server: ServerMcpServer, on local: any CodevisorServerClienting
  ) async throws -> ServerMcpServer {
    guard let copy = try await local.listMcpServers().first(where: { $0.isSamePlugin(as: server) }) else {
      throw PluginSignInError.notOnThisMac(plugin: server.name)
    }
    return copy
  }

  private static func relaysThroughCloud(_ machineId: String, statusByMachineId: [String: MachineStatus]) -> Bool {
    CodevisorMachine.cloudDeviceId(forMachineId: machineId) != nil || statusByMachineId[machineId]?.cloudDeviceId != nil
  }
}

public struct PluginSignInStart: Equatable, Sendable {
  public let authorizationUrl: String
  public let serverId: String
  public let machineId: String
}

enum PluginSignInError: LocalizedError {
  case offCloud(machine: String, plugin: String)
  case notOnThisMac(plugin: String)
  case removed

  var errorDescription: String? {
    switch self {
    case let .offCloud(machine, plugin):
      "\(machine) isn't signed in to Codevisor Cloud, so \(plugin) sign-in can't finish on this device. "
        + "Sign \(machine) in to Codevisor Cloud, then try again."
    case let .notOnThisMac(plugin):
      "\(plugin) isn't on this Mac. Turn it on here to sign in, and the sign-in reaches your other machines too."
    case .removed:
      "That plugin isn't installed on this machine anymore."
    }
  }
}

extension ServerMcpServer {
  func isSamePlugin(as other: ServerMcpServer) -> Bool {
    if let catalogId, catalogId == other.catalogId { return true }
    return name == other.name
  }
}
