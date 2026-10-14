import Foundation

public extension PluginFleet {
  enum MachineStatus: Equatable, Sendable {
    case ready
    case off
    case installing
    case blocked(reason: String)
    case localOnly
    case unreachable
    case syncing

    public var label: String {
      switch self {
      case .ready: "Ready"
      case .off: "Off"
      case .installing: "Installing…"
      case .blocked: "Needs attention"
      case .localOnly: "Only on this machine"
      case .unreachable: "Unreachable"
      case .syncing: "Syncing…"
      }
    }

    public var isRunningHere: Bool {
      switch self {
      case .ready, .localOnly: true
      default: false
      }
    }

    public var rowStatus: FleetRowStatus {
      switch self {
      case .ready: .ready()
      case .blocked(let reason): .attention(label, reason: reason)
      case .installing, .syncing: .busy(label)
      case .off, .localOnly, .unreachable: .quiet(label)
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

  nonisolated static func machineStatus(state: String, reason: String?) -> MachineStatus {
    switch state {
    case "ready": .ready
    case "disabled": .off
    case "notInstalled": .installing
    case "blocked": .blocked(reason: reason ?? FleetRowStatus.blockedFallbackReason)
    case "machineOnly": .localOnly
    default: .syncing
    }
  }

  nonisolated static func machineRows(
    pluginId: String, readiness: [String: [MachineReadiness]], machines: [FleetMachineInfo],
    wantsOn: Bool = false
  ) -> [MachineRow] {
    machines.map { machine in
      var status: MachineStatus
      if !machine.isReachable {
        status = .unreachable
      } else if let key = machine.syncKey,
        let row = readiness[key]?.first(where: { $0.pluginId == pluginId })
      {
        status = machineStatus(state: row.state, reason: row.reason)
        if status == .off, wantsOn { status = .syncing }
      } else {
        status = .syncing
      }
      return MachineRow(machineId: machine.id, name: machine.name, status: status)
    }
  }

  static func rows(
    pluginId: String, sync: ConfigSync, machines: [FleetMachineInfo]
  ) -> [MachineRow] {
    machineRows(
      pluginId: pluginId, readiness: readiness(sync), machines: machines,
      wantsOn: settings(sync).first { $0.id == pluginId }?.enabled ?? false)
  }
}
