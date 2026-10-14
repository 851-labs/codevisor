import CodevisorClient
import Foundation

extension CloudAccountController {
  func reconcileDirectPaths() {
    guard state.isSignedIn, hubConnection() != nil else {
      directPaths.dropAll()
      return
    }
    directPaths.reconcile(machines: machines.filter { $0.online && verifiedMachineKey(for: $0) != nil })
  }

  func machineTransport(forDeviceId deviceId: String) -> any CloudChannelTransport {
    let directPaths = directPaths
    return SwitchingChannelTransport(machineDeviceId: deviceId) { [weak self] in
      guard let target = await self?.tunnelTarget(forDeviceId: deviceId) else {
        throw MachineUnreachableError(machineId: CodevisorMachine.cloudIdPrefix + deviceId)
      }
      return try await directPaths.awaitTransport(
        for: deviceId, publicKey: target.verifiedKey, machine: target.machine)
    }
  }

  public func relayServerConfig(forDeviceId deviceId: String) -> CodevisorServerConfig? {
    guard hubConnection() != nil else { return nil }
    return tunnelServerConfig(deviceId: deviceId, baseURL: CodevisorMachine.cloudPlaceholderBaseURL)
  }

  func tunnelServerConfig(deviceId: String, baseURL: URL) -> CodevisorServerConfig {
    let endpoint = machineTransport(forDeviceId: deviceId)
    return CodevisorServerConfig(
      baseURL: baseURL,
      bearerToken: nil,
      requestTransport: CloudRelayRequestTransport(endpoint: endpoint),
      webSocketTransport: CloudRelayWebSocketTransport(endpoint: endpoint)
    )
  }

  func tunnelTarget(forDeviceId deviceId: String) -> (machine: CloudMachine, verifiedKey: String)? {
    guard state.isSignedIn,
      let machine = machines.first(where: { $0.deviceId == deviceId }),
      let key = verifiedMachineKey(for: machine)
    else { return nil }
    return (machine, key)
  }
}

extension CloudAccountController {
  public func tunnelMediaRoute(for machine: CloudMachine) async -> CloudTunnelMediaRoute? {
    guard state.isSignedIn, let address = machine.tunnel, verifiedMachineKey(for: machine) != nil
    else { return nil }
    return await directPaths.tunnel.openMediaRoute(to: address)
  }
}
