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

  public var readyMachineIds: Set<String> {
    Set(allMachines.filter { availability(for: $0.id) == .ready }.map(\.id))
  }

  public func sandboxProfilesLoadKey(composerId: String) -> SandboxProfilesLoadKey {
    SandboxProfilesLoadKey(
      composerId: composerId,
      machineAvailabilities: Dictionary(uniqueKeysWithValues: allMachines.map { ($0.id, availability(for: $0.id)) }),
      machineServerIds: Dictionary(uniqueKeysWithValues: allMachines.map { ($0.id, reportedServerId(of: $0.id)) }),
      revision: sandboxAvailabilityRevision
    )
  }

  public var sandboxMachineProfilesLoadKey: SandboxMachineProfilesLoadKey {
    SandboxMachineProfilesLoadKey(
      sandboxDeviceIds: Set(sandboxCloudMachines.map(\.deviceId)),
      ownerAvailabilities: sandboxOwnerMachineIds.mapValues { $0.map(availability(for:)) },
      revision: sandboxSettingsRevision
    )
  }

  public func loadSandboxMachineProfiles() async {
    let owners = sandboxOwnerMachineIds.compactMap { deviceId, machineId -> SandboxOwner? in
      guard let machineId, availability(for: machineId) == .ready else { return nil }
      return SandboxOwner(deviceId: deviceId, client: client(for: machineId))
    }
    await sandboxMachineProfiles.load(from: owners)
  }

  public func sandboxPower(forMachineId id: String) -> SandboxMachinePower? {
    guard let cloud = cloudMachine(forMachineId: id), let origin = cloud.ephemeral else { return nil }
    guard !(cloud.online && availability(for: id) == .ready) else { return nil }
    return sandboxMachineProfiles.power(forDevice: cloud.deviceId, ownedBy: origin.ownerDeviceId)
  }

  public func wakeSandbox(forMachineId id: String) async throws {
    guard let paused = sandboxPower(forMachineId: id), paused.power == .paused else { return }
    guard let cloud = cloudMachine(forMachineId: id), let origin = cloud.ephemeral,
      let ownerMachineId = ownerMachineId(of: origin)
    else { return }

    sandboxMachineProfiles.markWaking(device: cloud.deviceId, ownedBy: origin.ownerDeviceId)
    do {
      _ = try await client(for: ownerMachineId).wakeSandbox(id: paused.sandboxId)
    } catch {
      sandboxSettingsRevision += 1
      throw error
    }
  }

  public func sandboxOwnerMachineId(forMachineId id: String) -> String? {
    cloudMachine(forMachineId: id)?.ephemeral.flatMap(ownerMachineId(of:))
  }

  private var sandboxCloudMachines: [CloudMachine] {
    allMachines.compactMap { cloudMachine(forMachineId: $0.id) }.filter { $0.ephemeral != nil }
  }

  private var sandboxOwnerMachineIds: [String: String?] {
    var owners: [String: String?] = [:]
    for origin in sandboxCloudMachines.compactMap(\.ephemeral) {
      owners[origin.ownerDeviceId] = ownerMachineId(of: origin)
    }
    return owners
  }

  private func ownerMachineId(of origin: CloudEphemeralOrigin) -> String? {
    canonicalComposerMachineId(for: CodevisorMachine.cloudIdPrefix + origin.ownerDeviceId)
  }

  public func sandboxHostConnection(forServerId serverId: String) -> SandboxHostConnection {
    guard let machineId = machineId(forServerId: serverId) else {
      return isLocalServerStarting ? .starting : .unreachable
    }
    if availability(for: machineId) == .ready { return .ready(client(for: machineId)) }
    return machineId == CodevisorMachine.local.id && isLocalServerStarting ? .starting : .unreachable
  }

  private var isLocalServerStarting: Bool {
    let local = CodevisorMachine.local.id
    guard allMachines.contains(where: \.isLocal) else { return false }
    switch availability(for: local) {
    case .waiting: return true
    case .ready: return reportedServerId(of: local) == nil
    case .failed: return false
    }
  }

  private func reportedServerId(of machineId: String) -> String? {
    connectionsById[machineId]?.status?.serverId
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
