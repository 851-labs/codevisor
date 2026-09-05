import CodevisorClient
import Foundation

/// Client and transport routing: how a machine id becomes something the
/// app can actually talk to — relay-backed for cloud ids and configured
/// machines in fallback, plain HTTP for active direct routes, and a
/// loudly-failing client when a cloud id can't be routed yet.
extension MachineController {
  func clientIfKnown(for machineId: String) -> (any CodevisorServerClienting)? {
    guard machine(for: machineId) != nil else { return nil }
    return client(for: machineId)
  }

  public func client(for machineId: String) -> any CodevisorServerClienting {
    // Cloud machines — including configured machines whose direct route
    // has failed over to their persisted cloud twin — get a real HTTP
    // client whose transports tunnel every request/WebSocket through the
    // account's encrypted relay, so all existing features work unchanged.
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
    return clientFactory(machine)
  }

  /// The relay config backing a CONFIGURED machine's fallback route, via
  /// the cloud device id persisted on its record. Nil without a link or a
  /// signed-in cloud account.
  func relayFallbackConfig(forConfiguredMachineId machineId: String) -> CodevisorServerConfig? {
    guard let cloud = configuredCloudMachine(forMachineId: machineId), let cloudProvider
    else { return nil }
    return cloudProvider.relayServerConfig(for: cloud)
  }

  /// The route a machine's traffic is currently using.
  func routeInUse(forMachineId machineId: String) -> MachineRoute {
    statusByMachineId[machineId]?.route == .relay ? .relay : .direct
  }

  /// The server config for a machine id — relay-backed for cloud machines
  /// and configured machines in fallback, plain for active direct routes.
  /// Consumers that build their own transports from a config (terminals)
  /// use this so every feature observes the same selected route.
  public func serverConfig(for machineId: String) -> CodevisorServerConfig {
    if let config = relayServerConfig(forMachineId: machineId) {
      return config
    }
    return machine(for: machineId)?.serverConfig ?? .unreachable(machineId: machineId)
  }

  private func relayServerConfig(forMachineId machineId: String) -> CodevisorServerConfig? {
    guard let cloud = relayMachine(forMachineId: machineId) else { return nil }
    return cloudProvider?.relayServerConfig(for: cloud)
  }

  /// The machine's effective HTTP origin for consumers that must dial a
  /// real socket instead of the in-process relay transports (plugin pane
  /// webviews, external helper processes): direct machines answer their
  /// configured baseURL; cloud machines lazily start the in-app loopback
  /// bridge and answer its `http://127.0.0.1:<port>` address, waiting
  /// (bounded) for the listener to come up. Configured machines currently
  /// using their cloud fallback take that same bridge path, so raw-socket
  /// consumers observe the same active route as API clients. Nil when the
  /// machine is gone or the relay bridge can't start (signed out, relay
  /// down).
  public func effectiveHTTPBaseURL(
    forMachineId machineId: String,
    timeout: Duration = .seconds(10),
    scheduler: ServerUpdateScheduler = .continuous
  ) async -> URL? {
    guard let cloud = relayMachine(forMachineId: machineId) else {
      // A cloud identity, or a configured machine already marked as
      // relayed, must never leak back to a stale direct origin when its
      // bridge is temporarily unavailable.
      if CodevisorMachine.cloudDeviceId(forMachineId: machineId) != nil
        || statusByMachineId[machineId]?.route == .relay
      {
        return nil
      }
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

  /// The cloud presence record carrying the machine's active route. A
  /// `cloud:` id resolves directly; a configured id resolves through its
  /// persisted twin only after reachability has selected relay fallback.
  private func relayMachine(forMachineId machineId: String) -> CloudMachine? {
    if let cloud = cloudMachine(forMachineId: machineId) { return cloud }
    guard statusByMachineId[machineId]?.route == .relay else { return nil }
    return configuredCloudMachine(forMachineId: machineId)
  }

  /// The cloud twin persisted on a manually configured machine, independent
  /// of whether reachability has selected that route yet. Status probing
  /// uses this to test fallback; active consumers go through
  /// `relayMachine(forMachineId:)` so direct routes stay direct.
  private func configuredCloudMachine(forMachineId machineId: String) -> CloudMachine? {
    guard
      let deviceId = registry.remoteMachines.first(where: { $0.id == machineId })?
        .cloudDeviceId,
      let cloudProvider, cloudProvider.isCloudSignedIn
    else { return nil }
    return cloudProvider.cloudMachines.first { $0.deviceId == deviceId }
  }
}
