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
  func machineTransport(for machine: CloudMachine, verifiedKey: String) -> any CloudChannelTransport {
    let directPaths = directPaths
    let deviceId = machine.deviceId
    return SwitchingChannelTransport(machineDeviceId: deviceId) {
      try await directPaths.awaitTransport(for: deviceId, publicKey: verifiedKey)
    }
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
