import Foundation

@MainActor
final class MachineCatalog {
  var cloudProvider: (any CloudMachineProviding)?

  private let includesLocalMachine: Bool
  private let connections: MachineConnections

  init(includesLocalMachine: Bool, connections: MachineConnections) {
    self.includesLocalMachine = includesLocalMachine
    self.connections = connections
  }

  var machines: [CodevisorMachine] {
    guard includesLocalMachine else { return [] }
    var local = CodevisorMachine.local
    let presence = localCloudMachine
    if let presence { local.name = presence.name }
    local.icon = icon(chosen: presence?.icon, reportedBy: local.id)
    return [local]
  }

  var allMachines: [CodevisorMachine] {
    machines
      + cloudOnlyMachines.map { cloud in
        var machine = CodevisorMachine.cloud(from: cloud)
        machine.icon = icon(chosen: cloud.icon, reportedBy: machine.id)
        if let loopback = cloudProvider?.loopbackBaseURL(for: cloud) {
          machine.baseURL = loopback
        }
        return machine
      }
  }

  var cloudOnlyMachines: [CloudMachine] {
    guard let cloudProvider, cloudProvider.isCloudSignedIn else { return [] }
    let configuredIds = Set(machines.map(\.id))
    let knownCloudIds = Set(
      connections.statusById
        .filter { configuredIds.contains($0.key) }
        .values
        .compactMap(\.cloudDeviceId)
    )
    let knownNames: Set<String> = includesLocalMachine ? [CodevisorMachine.local.name] : []
    return cloudProvider.cloudMachines.filter {
      !knownCloudIds.contains($0.deviceId) && !knownNames.contains($0.name)
    }
  }

  var localCloudMachine: CloudMachine? {
    guard let deviceId = connections.statusById[CodevisorMachine.local.id]?.cloudDeviceId,
      let cloudProvider, cloudProvider.isCloudSignedIn
    else { return nil }
    return cloudProvider.cloudMachines.first { $0.deviceId == deviceId }
  }

  func machine(for id: String) -> CodevisorMachine? {
    allMachines.first { $0.id == id }
  }

  func cloudMachine(forMachineId id: String) -> CloudMachine? {
    guard let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: id),
      let cloudProvider, cloudProvider.isCloudSignedIn
    else { return nil }
    return cloudProvider.cloudMachines.first { $0.deviceId == deviceId }
  }

  func icon(for cloud: CloudMachine) -> MachineIcon {
    let machineId =
      cloud.deviceId == localCloudMachine?.deviceId
      ? CodevisorMachine.local.id : CodevisorMachine.cloudIdPrefix + cloud.deviceId
    return icon(chosen: cloud.icon, reportedBy: machineId)
  }

  func isCloudTwinOfConfiguredMachine(_ machineId: String) -> Bool {
    guard let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: machineId) else {
      return false
    }
    let configuredIds = Set(machines.map(\.id))
    return connections.statusById.contains { key, status in
      configuredIds.contains(key) && status.cloudDeviceId == deviceId
    }
  }

  func canonicalComposerMachineId(for id: String) -> String? {
    if machine(for: id) != nil, !isCloudTwinOfConfiguredMachine(id) {
      return id
    }
    guard let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: id) else {
      return nil
    }
    return machines.first {
      connections.statusById[$0.id]?.cloudDeviceId == deviceId
    }?.id
  }

  func fleetMachineName(for serverId: String) -> String? {
    machine(for: serverId)?.name
  }

  func machineId(forSyncKey key: String) -> String? {
    connections.statusById.first { $0.value.serverId == key }?.key
  }

  func syncKey(forMachineId id: String) -> String? {
    connections.statusById[id]?.serverId
  }

  func fleetName(forSyncKey key: String) -> String {
    guard let machineId = machineId(forSyncKey: key) else { return key }
    return fleetMachineName(for: machineId) ?? key
  }

  private func icon(chosen: String?, reportedBy machineId: String) -> MachineIcon {
    MachineIcon(known: chosen) ?? MachineIcon(resolving: connections.reportedIcon(for: machineId))
  }
}
