import CodevisorClient
import Foundation

/// Client and transport routing: how a machine id becomes something the
/// app can actually talk to — relay-backed for cloud ids, plain HTTP for
/// the local machine, and a loudly-failing client when a cloud id can't be
/// routed yet.
extension MachineController {
  public struct HTTPConnectionState: Equatable {
    let directURL: URL?
    let relayDeviceId: String?
    let revision: UInt64
  }

  /// Observed by raw-socket consumers, including cached browser/plugin panes.
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

  func clientIfKnown(for machineId: String) -> (any CodevisorServerClienting)? {
    guard machine(for: machineId) != nil else { return nil }
    return client(for: machineId)
  }

  public func client(for machineId: String) -> any CodevisorServerClienting {
    if let injectedClientFactory, let machine = machine(for: machineId) {
      return injectedClientFactory(machine)
    }
    // Cloud machines get a real HTTP client whose transports tunnel every
    // request/WebSocket through the account's encrypted relay, so all
    // existing features work unchanged.
    if let config = relayServerConfig(forMachineId: machineId) {
      return CodevisorServerClient(
        config: config,
        requestGate: requestGate,
        machineId: machineId
      )
    }
    // A cloud machine id with no relay yet (launch-time roster still
    // loading, signed out, relay down) must FAIL its requests, never
    // silently answer as the local machine: a draft restored onto a
    // cloud project at launch once fetched the local server's harness
    // catalog through this fallback and persisted it under the cloud
    // machine's cache key — poisoning every later composer open.
    if CodevisorMachine.cloudDeviceId(forMachineId: machineId) != nil {
      return CodevisorServerClient(config: .unreachable(machineId: machineId))
    }
    guard let machine = machine(for: machineId) else {
      return CodevisorServerClient(config: .unreachable(machineId: machineId))
    }
    return CodevisorServerClient(config: machine.serverConfig, requestGate: requestGate, machineId: machine.id)
  }

  /// The server config for a machine id — relay-backed for cloud machines,
  /// plain for the local machine. Consumers that build their own transports
  /// from a config (terminals) use this so every feature observes the same
  /// route.
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

  /// The machine's effective HTTP origin for consumers that must dial a
  /// real socket instead of the in-process relay transports (plugin pane
  /// webviews, external helper processes): the local machine answers its
  /// baseURL; cloud machines lazily start the in-app loopback bridge and
  /// answer its `http://127.0.0.1:<port>` address, waiting (bounded) for the
  /// listener to come up. Nil when the machine is gone or the relay bridge
  /// can't start (signed out, relay down).
  public func effectiveHTTPBaseURL(
    forMachineId machineId: String,
    timeout: Duration = .seconds(10),
    scheduler: ServerUpdateScheduler = .continuous
  ) async -> URL? {
    guard let cloud = cloudMachine(forMachineId: machineId) else {
      // A cloud identity must never leak back to its placeholder origin
      // when its bridge is temporarily unavailable.
      if CodevisorMachine.cloudDeviceId(forMachineId: machineId) != nil { return nil }
      return machine(for: machineId)?.baseURL
    }
    guard let cloudProvider else { return nil }
    // The first call kicks the bridge off; poll for the published port —
    // it appears via an observable the synchronous accessor can't await.
    let deadline = scheduler.now() + timeout
    while true {
      if let url = cloudProvider.loopbackBaseURL(for: cloud) { return url }
      guard scheduler.now() < deadline, !Task.isCancelled else { return nil }
      try? await scheduler.sleep(.milliseconds(100))
    }
  }

  /// A screen-sharing media route over the tunnel to a cloud-reached
  /// machine (docs/plans/codevisor-tunnel.md); nil for the local machine or
  /// when the machine has no tunnel.
  public func tunnelMediaRoute(forMachineId machineId: String) async -> CloudTunnelMediaRoute? {
    guard let cloud = cloudMachine(forMachineId: machineId) else { return nil }
    return await cloudProvider?.tunnelMediaRoute(for: cloud)
  }
}
