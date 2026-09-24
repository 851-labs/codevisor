import Foundation

/// The plugin-major read of the desired-vs-reported matrix: for one plugin,
/// what every machine says about it. The fleet toggle is the only control on
/// the entry; machines converge on their own, so a machine row is a status —
/// never a place to install.
public extension PluginFleet {
  /// One plugin on one machine, reduced to the single word the row shows.
  enum MachineStatus: Equatable, Sendable {
    case ready
    /// The fleet turned it off; the machine has applied that.
    case off
    /// Reported as not installed; the machine's next pass installs it.
    case installing
    case blocked(reason: String)
    /// A linked/dev or local-path plugin: it lives only here and never syncs.
    case localOnly
    case unreachable
    /// No report yet: the machine hasn't been probed, or hasn't learned this plugin.
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

    /// The plugin is present and expected to be running here, so restarting
    /// it on this machine is a meaningful thing to offer. A machine-bound
    /// plugin reports `machineOnly` rather than `ready` — it is running all
    /// the same, and the old per-machine page let you restart it.
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

  /// The one mapping from a server's reported state string.
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

  /// Machines keep their list order regardless of state, so rows don't jump
  /// while a fleet converges. An unreachable machine's last report is stale
  /// by definition and never outranks the fact that it is offline.
  nonisolated static func machineRows(
    pluginId: String, readiness: [String: [MachineReadiness]], machines: [FleetMachineInfo]
  ) -> [MachineRow] {
    machines.map { machine in
      let status: MachineStatus
      if !machine.isReachable {
        status = .unreachable
      } else if let key = machine.syncKey,
        let row = readiness[key]?.first(where: { $0.pluginId == pluginId })
      {
        status = machineStatus(state: row.state, reason: row.reason)
      } else {
        status = .syncing
      }
      return MachineRow(machineId: machine.id, name: machine.name, status: status)
    }
  }

  static func rows(
    pluginId: String, sync: ConfigSync, machines: [FleetMachineInfo]
  ) -> [MachineRow] {
    machineRows(pluginId: pluginId, readiness: readiness(sync), machines: machines)
  }
}
