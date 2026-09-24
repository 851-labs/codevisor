import Foundation

/// The server-major read of the desired-vs-reported matrix: for one MCP
/// server, what every machine says about it. Unlike harnesses, MCPs have a
/// real per-machine control — the `mcp-overlays` disable — so a machine row
/// carries a toggle as well as a status.
public extension McpFleet {
  /// One MCP server on one machine, reduced to what the row shows.
  enum MachineStatus: Equatable, Sendable {
    case ready(toolCount: Int?)
    case connecting
    /// Enabled and healthy, but nothing has needed it yet.
    case idle
    /// The authorization this machine holds is missing or expired. Distinct
    /// from `blocked` because the fix is a sign-in, not a look at a log.
    case needsAuthorization(reason: String)
    /// Local setup this machine hasn't done — a browser extension, a
    /// permission, the native app not being open.
    case needsSetup(reason: String)
    case blocked(reason: String)
    /// Switched off by this machine's own overlay.
    case offHere
    /// The fleet turned the server off; nothing machine-specific about it.
    case offFleet
    case unreachable
    /// No report yet: the machine hasn't been probed, or hasn't learned it.
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

    /// True while the machine is switched on here, whatever its health —
    /// what the machine row's toggle reflects.
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

  /// The one mapping from a server's reported row. `code` carries the raw
  /// connection state so an expired authorization can offer a sign-in while
  /// a missing binary offers a log.
  nonisolated static func machineStatus(_ row: MachineReadiness) -> MachineStatus {
    switch row.state {
    case "ready": return .ready(toolCount: row.toolCount)
    case "connecting": return .connecting
    case "idle": return .idle
    case "disabled":
      // The publisher distinguishes the two disables in its reason; the
      // client re-derives "here" from the overlay it can see directly, so
      // this only has to name the fleet-wide case.
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

  /// Machines keep their list order regardless of state, so rows don't jump
  /// while a fleet converges. The overlay outranks the report: a machine
  /// switched off here reads as off immediately, without waiting for it to
  /// notice and republish.
  nonisolated static func machineRows(
    name: String,
    readiness: [String: [MachineReadiness]],
    disabledKeys: Set<String>,
    machines: [FleetMachineInfo]
  ) -> [MachineRow] {
    machines.map { machine in
      let status: MachineStatus
      if let key = machine.syncKey, disabledKeys.contains(key) {
        status = .offHere
      } else if !machine.isReachable {
        status = .unreachable
      } else if let key = machine.syncKey,
        let row = readiness[key]?.first(where: { $0.name == name })
      {
        status = machineStatus(row)
      } else {
        status = .syncing
      }
      return MachineRow(machineId: machine.id, name: machine.name, status: status)
    }
  }

  /// A built-in's switch is that machine's own `enabled` flag — built-ins
  /// never replicate — so the overlay plane has nothing to say about them.
  /// Managed servers read their per-machine state from the overlay.
  static func rowsRespectingBuiltIns(
    name: String,
    isMachineScoped: Bool,
    enabledByMachine: [String: Bool],
    sync: ConfigSync,
    machines: [FleetMachineInfo]
  ) -> [MachineRow] {
    let derived = rows(name: name, sync: sync, machines: machines)
    guard isMachineScoped else { return derived }
    return derived.map { row in
      guard enabledByMachine[row.machineId] == false else { return row }
      var copy = row
      copy.status = .offHere
      return copy
    }
  }

  static func rows(name: String, sync: ConfigSync, machines: [FleetMachineInfo]) -> [MachineRow] {
    let disabled = Set(
      machines.compactMap { machine -> String? in
        guard let key = machine.syncKey,
          isDisabled(sync, machineId: key, name: name)
        else { return nil }
        return key
      })
    return machineRows(
      name: name, readiness: readiness(sync), disabledKeys: disabled, machines: machines)
  }
}
