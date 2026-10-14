import Foundation

public extension McpFleet {
  enum MachineStatus: Equatable, Sendable {
    case ready(toolCount: Int?)
    case connecting
    case idle
    case needsAuthorization(reason: String)
    case needsSetup(reason: String)
    case blocked(reason: String)
    case offHere
    case offFleet
    case unreachable
    case syncing

    public var label: String {
      switch self {
      case .ready(let toolCount):
        toolCount.map { "Connected · \($0) tool\($0 == 1 ? "" : "s")" } ?? "Connected"
      case .connecting: "Connecting…"
      case .idle: "Ready"
      case .needsAuthorization: "Authorization required"
      case .needsSetup: "Setup required"
      case .blocked: "Needs attention"
      case .offHere: "Off here"
      case .offFleet: "Off"
      case .unreachable: "Unreachable"
      case .syncing: "Syncing…"
      }
    }

    public var rowStatus: FleetRowStatus {
      switch self {
      case .ready, .idle: .ready(label)
      case .connecting, .syncing: .busy(label)
      case .needsAuthorization(let reason): .attention(label, reason: reason)
      case .needsSetup(let reason): .attention(label, reason: reason)
      case .blocked(let reason): .attention(label, reason: reason)
      case .offHere, .offFleet, .unreachable: .quiet(label)
      }
    }

    public var isOnHere: Bool {
      switch self {
      case .offHere: false
      default: true
      }
    }
  }

  struct MachineRow: Identifiable, Equatable, Sendable {
    public var machineId: String
    public var name: String
    public var status: MachineStatus
    public var id: String { machineId }

    public init(machineId: String, name: String, status: MachineStatus) {
      self.machineId = machineId
      self.name = name
      self.status = status
    }
  }

  nonisolated static func machineStatus(_ row: MachineReadiness) -> MachineStatus {
    switch row.state {
    case "ready": return .ready(toolCount: row.toolCount)
    case "connecting": return .connecting
    case "idle": return .idle
    case "disabled":
      return .offFleet
    default:
      let reason = row.reason ?? FleetRowStatus.blockedFallbackReason
      switch row.code {
      case "needsAuthorization", "expired": return .needsAuthorization(reason: reason)
      case "needsSetup", "unavailable": return .needsSetup(reason: reason)
      default: return .blocked(reason: reason)
      }
    }
  }

  nonisolated static func machineRows(
    name: String,
    readiness: [String: [MachineReadiness]],
    disabledKeys: Set<String>,
    machines: [FleetMachineInfo],
    wantsOn: (String) -> Bool = { _ in false }
  ) -> [MachineRow] {
    machines.map { machine in
      var status: MachineStatus
      if let key = machine.syncKey, disabledKeys.contains(key) {
        status = .offHere
      } else if !machine.isReachable {
        status = .unreachable
      } else if let key = machine.syncKey,
        let row = readiness[key]?.first(where: { $0.name == name })
      {
        status = machineStatus(row)
        if status == .offFleet, wantsOn(machine.id) { status = .syncing }
      } else {
        status = .syncing
      }
      return MachineRow(machineId: machine.id, name: machine.name, status: status)
    }
  }

  static func rowsRespectingBuiltIns(
    name: String,
    isMachineScoped: Bool,
    enabledByMachine: [String: Bool],
    fleetEnabled: Bool = false,
    turningOn: Set<String> = [],
    sync: ConfigSync,
    machines: [FleetMachineInfo]
  ) -> [MachineRow] {
    let wantsOn: (String) -> Bool = { machineId in
      isMachineScoped ? enabledByMachine[machineId] == true : fleetEnabled
    }
    let derived = rows(name: name, sync: sync, machines: machines, wantsOn: wantsOn)
    return derived.map { row in
      var copy = row
      if isMachineScoped, enabledByMachine[row.machineId] == false {
        copy.status = .offHere
      } else if turningOn.contains(row.machineId), row.status != .offHere, row.status != .unreachable {
        copy.status = .syncing
      }
      return copy
    }
  }

  static func rows(
    name: String, sync: ConfigSync, machines: [FleetMachineInfo],
    wantsOn: (String) -> Bool = { _ in false }
  ) -> [MachineRow] {
    let disabled = Set(
      machines.compactMap { machine -> String? in
        guard let key = machine.syncKey,
          isDisabled(sync, machineId: key, name: name)
        else { return nil }
        return key
      })
    return machineRows(
      name: name, readiness: readiness(sync), disabledKeys: disabled, machines: machines,
      wantsOn: wantsOn)
  }
}
