import CodevisorClient
import Foundation

// MARK: - Tunnel pipes

extension CloudAccountController {
  /// Re-dials tunnel pipes after each machine refresh. Only online machines
  /// whose presented key matches the TOFU pin are candidates — a
  /// changed-key machine gets no pipe until the user re-trusts it, and the
  /// pin is what every channel seals toward.
  func reconcileDirectPaths() {
    guard state.isSignedIn, hubConnection() != nil else {
      directPaths.dropAll()
      return
    }
    directPaths.reconcile(machines: machines.filter { $0.online && verifiedMachineKey(for: $0) != nil })
  }

  /// One transport per machine: its tunnel pipe, waited for briefly while
  /// it is being dialed. Channels are ephemeral, so a re-dialed pipe simply
  /// carries the next open — nothing migrates.
  ///
  /// The machine and its verified key are looked up on every open, not
  /// captured: clients built from this transport live as long as the chats
  /// holding them, and must follow a roster that arrived after launch or a
  /// key the user re-trusted, instead of failing for the rest of the process.
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

  /// Tunnel transports for a device id, resolved per request (see
  /// `CloudMachineProviding.relayServerConfig(forDeviceId:)`).
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

  /// The machine as the roster knows it now, and its key iff it matches the
  /// TOFU pin. Nil while signed out, before the roster or pins are loaded,
  /// and for a machine whose key changed until the user re-trusts it.
  func tunnelTarget(forDeviceId deviceId: String) -> (machine: CloudMachine, verifiedKey: String)? {
    guard state.isSignedIn,
      let machine = machines.first(where: { $0.deviceId == deviceId }),
      let key = verifiedMachineKey(for: machine)
    else { return nil }
    return (machine, key)
  }
}

// MARK: - Tunnel media

extension CloudAccountController {
  /// A screen-sharing media route over the tunnel, for a machine whose
  /// presence carries a tunnel address and whose key is verified (the same
  /// gate every other pipe to it passes).
  public func tunnelMediaRoute(for machine: CloudMachine) async -> CloudTunnelMediaRoute? {
    guard state.isSignedIn, let address = machine.tunnel, verifiedMachineKey(for: machine) != nil
    else { return nil }
    return await directPaths.tunnel.openMediaRoute(to: address)
  }
}
