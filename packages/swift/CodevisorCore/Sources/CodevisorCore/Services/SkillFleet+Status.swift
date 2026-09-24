import Foundation

/// The skill-major read of the desired-vs-reported matrix. Skills have no
/// enable switch, so a machine row is purely a report plus — when the
/// machine has fallen behind its harnesses — the one action that fixes it.
public extension SkillFleet {
  enum MachineStatus: Equatable, Sendable {
    case ready
    /// Present, but some harness on that machine has no materialized copy.
    case outOfSync(reason: String)
    /// The replica names this skill but no machine has ferried its bytes
    /// here yet. The one failure the old per-machine page could not show.
    case awaitingContent(reason: String?)
    case conflict(reason: String)
    case invalid(reason: String)
    /// Exists only here; never published to the fleet.
    case localOnly
    case unreachable
    case syncing

    public var label: String {
      switch self {
      case .ready: "Available"
      case .outOfSync: "Not in every harness"
      case .awaitingContent: "Waiting for content"
      case .conflict: "Conflicting copy"
      case .invalid: "Invalid SKILL.md"
      case .localOnly: "Only on this machine"
      case .unreachable: "Unreachable"
      case .syncing: "Syncing…"
      }
    }

    public var rowStatus: FleetRowStatus {
      switch self {
      case .ready: .ready(label)
      case .outOfSync(let reason): .attention(label, reason: reason)
      case .conflict(let reason): .attention(label, reason: reason)
      case .invalid(let reason): .attention(label, reason: reason)
      case .awaitingContent(let reason): .busy(reason == nil ? label : "\(label)…")
      case .syncing: .busy(label)
      case .localOnly, .unreachable: .quiet(label)
      }
    }

    /// Only a machine that has the content but hasn't spread it to its
    /// harnesses can act; everything else is waiting on the ferry.
    public var canSync: Bool {
      if case .outOfSync = self { return true }
      return false
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
    case "outOfSync": .outOfSync(reason: reason ?? "Not available in every harness here.")
    case "awaitingContent": .awaitingContent(reason: reason)
    case "conflict": .conflict(reason: reason ?? "A harness copy has drifted from this skill.")
    case "invalid": .invalid(reason: reason ?? "This skill's SKILL.md could not be read.")
    case "machineOnly": .localOnly
    default: .syncing
    }
  }

  nonisolated static func machineRows(
    directoryName: String, readiness: [String: [MachineReadiness]], machines: [FleetMachineInfo]
  ) -> [MachineRow] {
    machines.map { machine in
      let status: MachineStatus
      if !machine.isReachable {
        status = .unreachable
      } else if let key = machine.syncKey,
        let row = readiness[key]?.first(where: { $0.directoryName == directoryName })
      {
        status = machineStatus(state: row.state, reason: row.reason)
      } else {
        status = .syncing
      }
      return MachineRow(machineId: machine.id, name: machine.name, status: status)
    }
  }

  static func rows(
    directoryName: String, sync: ConfigSync, machines: [FleetMachineInfo]
  ) -> [MachineRow] {
    machineRows(directoryName: directoryName, readiness: readiness(sync), machines: machines)
  }
}
