import Foundation

public struct FleetMachineInfo: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var syncKey: String?
  public var isReachable: Bool
  public var isLocal: Bool

  public init(id: String, name: String, syncKey: String?, isReachable: Bool, isLocal: Bool = false) {
    self.id = id
    self.name = name
    self.syncKey = syncKey
    self.isReachable = isReachable
    self.isLocal = isLocal
  }

  @MainActor
  public static func all(_ machines: MachineController) -> [FleetMachineInfo] {
    machines.allMachines.map { machine in
      FleetMachineInfo(
        id: machine.id,
        name: machine.name,
        syncKey: machines.syncKey(forMachineId: machine.id),
        isReachable: machines.statusByMachineId[machine.id]?.isReachable != false,
        isLocal: machine.isLocal)
    }
  }
}

public struct FleetRowStatus: Equatable, Sendable {
  public enum Emphasis: Equatable, Sendable {
    case ready
    case busy
    case attention
    case quiet
  }

  public var emphasis: Emphasis
  public var label: String
  public var reason: String?

  public init(emphasis: Emphasis, label: String, reason: String? = nil) {
    self.emphasis = emphasis
    self.label = label
    self.reason = reason
  }

  public var isBusy: Bool { emphasis == .busy }
  public var needsAttention: Bool { emphasis == .attention }

  public static func ready(_ label: String = "Ready") -> FleetRowStatus {
    FleetRowStatus(emphasis: .ready, label: label)
  }

  public static func busy(_ label: String) -> FleetRowStatus {
    FleetRowStatus(emphasis: .busy, label: label)
  }

  public static func attention(_ label: String, reason: String) -> FleetRowStatus {
    let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    return FleetRowStatus(
      emphasis: .attention, label: label, reason: reason.isEmpty ? blockedFallbackReason : reason)
  }

  public static func quiet(_ label: String) -> FleetRowStatus {
    FleetRowStatus(emphasis: .quiet, label: label)
  }

  public static let unreachable = FleetRowStatus.quiet("Unreachable")
  public static let syncing = FleetRowStatus.busy("Syncing…")

  nonisolated public static let blockedFallbackReason = "Couldn’t sync this to the machine."
  public var isWorthFoldingUp: Bool { emphasis != .ready && emphasis != .quiet }
}
