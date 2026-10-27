import CodevisorClient
import Foundation

extension MachineController {
  public struct HTTPConnectionState: Equatable {
    let directURL: URL?
    let relayDeviceId: String?
    let revision: UInt64
  }

  public func httpConnectionState(forMachineId machineId: String) -> HTTPConnectionState {
    if let cloud = cloudMachine(forMachineId: machineId) {
      return HTTPConnectionState(
        directURL: nil, relayDeviceId: cloud.deviceId,
        revision: cloudProvider?.loopbackRevision(for: cloud) ?? 0)
    }
    return HTTPConnectionState(directURL: machine(for: machineId)?.baseURL, relayDeviceId: nil, revision: 0)
  }

  public func recoverHTTPConnection(forMachineId machineId: String) async -> URL? {
    if let cloud = cloudMachine(forMachineId: machineId) {
      guard await cloudProvider?.recoverLoopbackBridge(for: cloud) == true else { return nil }
    }
    return await effectiveHTTPBaseURL(forMachineId: machineId)
  }

  public func machineId(forServerId serverId: String) -> String? {
    allMachines.first { connectionsById[$0.id]?.status?.serverId == serverId }?.id
  }

  public func client(forServerId serverId: String) -> (any CodevisorServerClienting)? {
    machineId(forServerId: serverId).map { client(for: $0) }
  }

  func clientIfKnown(for machineId: String) -> (any CodevisorServerClienting)? {
    guard machine(for: machineId) != nil else { return nil }
    return client(for: machineId)
  }

  public func client(for machineId: String) -> any CodevisorServerClienting {
    if let injectedClientFactory, let machine = machine(for: machineId) {
      return injectedClientFactory(machine)
    }
    if let config = relayServerConfig(forMachineId: machineId) {
      return CodevisorServerClient(
        config: config,
        requestGate: requestGate,
        machineId: machineId
      )
    }
    if let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: machineId) {
      if let config = cloudProvider?.relayServerConfig(forDeviceId: deviceId) {
        return CodevisorServerClient(config: config, requestGate: requestGate, machineId: machineId)
      }
      return CodevisorServerClient(config: .unreachable(machineId: machineId))
    }
    guard let machine = machine(for: machineId) else {
      return CodevisorServerClient(config: .unreachable(machineId: machineId))
    }
    return CodevisorServerClient(config: machine.serverConfig, requestGate: requestGate, machineId: machine.id)
  }

  public func serverConfig(for machineId: String) -> CodevisorServerConfig {
    if let config = relayServerConfig(forMachineId: machineId) {
      return config
    }
    return machine(for: machineId)?.serverConfig ?? .unreachable(machineId: machineId)
  }

  private func relayServerConfig(forMachineId machineId: String) -> CodevisorServerConfig? {
    guard let cloud = cloudMachine(forMachineId: machineId) else { return nil }
    return cloudProvider?.relayServerConfig(for: cloud)
  }

  public func effectiveHTTPBaseURL(
    forMachineId machineId: String,
    timeout: Duration = .seconds(10),
    scheduler: ServerUpdateScheduler = .continuous
  ) async -> URL? {
    guard let cloud = cloudMachine(forMachineId: machineId) else {
      if CodevisorMachine.cloudDeviceId(forMachineId: machineId) != nil { return nil }
      return machine(for: machineId)?.baseURL
    }
    guard let cloudProvider else { return nil }
    let deadline = scheduler.now() + timeout
    while true {
      if let url = cloudProvider.loopbackBaseURL(for: cloud) { return url }
      guard scheduler.now() < deadline, !Task.isCancelled else { return nil }
      try? await scheduler.sleep(.milliseconds(100))
    }
  }

  public func tunnelMediaRoute(forMachineId machineId: String) async -> CloudTunnelMediaRoute? {
    guard let cloud = cloudMachine(forMachineId: machineId) else { return nil }
    return await cloudProvider?.tunnelMediaRoute(for: cloud)
  }
}
