import CodevisorClient
import Foundation

public enum MachineAttention: Equatable, Sendable {
  case updateNeeded
  case removed
}

public enum MachineReach: Equatable, Sendable {
  case ready
  case quiet
  case busy(ServerWaitingReason)
  case needsAction(MachineAttention)
  case failed(String)
}

extension MachineController {
  public func reach(for machineId: String) -> MachineReach {
    if let attention = attention(for: machineId) { return .needsAction(attention) }
    switch availability(for: machineId) {
    case .ready: return .ready
    case .waiting(.connecting): return .quiet
    case .waiting(.starting) where machine(for: machineId)?.isLocal == false: return .quiet
    case let .waiting(reason): return .busy(reason)
    case let .failed(message): return failedReach(for: machineId, message: message)
    }
  }

  public func isAway(_ machineId: String) -> Bool {
    reach(for: machineId) == .quiet && connections.isAway(machineId)
  }

  public func attention(for machineId: String) -> MachineAttention? {
    if case .removed = workspaceMachine(for: machineId) { return .removed }
    guard availability(for: machineId) != .ready, !showsDeviceOffline,
      let machine = machine(for: machineId), !machine.isLocal,
      let presence = cloudMachine(forMachineId: machineId), presence.online, presence.tunnel == nil
    else { return nil }
    return .updateNeeded
  }

  private func failedReach(for machineId: String, message: String) -> MachineReach {
    if machine(for: machineId)?.isLocal == true { return .failed(message) }
    guard let upgrade = connectionsById[machineId]?.dataUpgradeProgress else { return .quiet }
    return upgrade.error.map(MachineReach.failed) ?? .busy(.updating)
  }
}

extension MachineAttention {
  public func title(machineName: String) -> String {
    switch self {
    case .updateNeeded: "\(machineName) needs an update"
    case .removed: "\(machineName) was removed"
    }
  }
}

extension MachineController {
  public func displayName(for machineId: String) -> String {
    machine(for: machineId)?.name ?? fleetMachineName(for: machineId) ?? "This machine"
  }
}
