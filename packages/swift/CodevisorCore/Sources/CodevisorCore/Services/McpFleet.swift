import Foundation

@MainActor
public enum McpFleet {
  public static let syncNamespaces = ["mcps", "mcp-readiness", "mcp-overlays"]

  public struct MachineReadiness: Identifiable, Equatable, Sendable {
    public let name: String
    public let state: String
    public let reason: String?
    public let code: String?
    public let toolCount: Int?
    public var id: String { name }

    public init(
      name: String, state: String, reason: String?, code: String? = nil, toolCount: Int? = nil
    ) {
      self.name = name
      self.state = state
      self.reason = reason
      self.code = code
      self.toolCount = toolCount
    }
  }

  public static func readiness(_ sync: ConfigSync) -> [String: [MachineReadiness]] {
    var result: [String: [MachineReadiness]] = [:]
    for entry in sync.entries(namespace: "mcp-readiness") where entry.deleted != true {
      guard case .object(let value) = entry.value,
        case .array(let servers) = value["servers"] ?? .null
      else { continue }
      result[entry.key] = servers.compactMap { server in
        guard case .object(let fields) = server,
          case .string(let name) = fields["name"] ?? .null,
          case .string(let state) = fields["state"] ?? .null
        else { return nil }
        let reason: String? =
          if case .string(let text) = fields["reason"] ?? .null { text } else { nil }
        let code: String? =
          if case .string(let text) = fields["code"] ?? .null { text } else { nil }
        let toolCount: Int? =
          if case .number(let value) = fields["toolCount"] ?? .null { Int(value) } else { nil }
        return MachineReadiness(
          name: name, state: state, reason: reason, code: code, toolCount: toolCount)
      }
    }
    return result
  }

  static func disableKey(machineId: String, name: String) -> String {
    "enable|\(machineId)|\(name)"
  }

  public static func isDisabled(_ sync: ConfigSync, machineId: String, name: String) -> Bool {
    guard
      case .object(let value)? = sync.value(
        namespace: "mcp-overlays",
        key: disableKey(machineId: machineId, name: name)
      )
    else { return false }
    return value["enabled"] == .bool(false)
  }

  public static func setDisabled(
    _ sync: ConfigSync,
    machineId: String,
    name: String,
    disabled: Bool
  ) {
    let key = disableKey(machineId: machineId, name: name)
    if disabled {
      sync.set(namespace: "mcp-overlays", key: key, value: .object(["enabled": .bool(false)]))
    } else {
      sync.remove(namespace: "mcp-overlays", key: key)
    }
  }

  public enum MachineStatus: Equatable, Sendable {
    case ready(toolCount: Int?)
    case connecting
    case idle
    case needsAuthorization(reason: String)
    case needsSetup(reason: String)
    case blocked(reason: String)
    case off
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
      case .off: "Off"
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
      case .off, .unreachable: .quiet(label)
      }
    }

    public var needsAuthorization: Bool {
      if case .needsAuthorization = self { true } else { false }
    }
  }

  public struct MachineRow: Identifiable, Equatable, Sendable {
    public var machineId: String
    public var name: String
    public var status: MachineStatus
    public var isOn: Bool
    public var id: String { machineId }

    public init(machineId: String, name: String, status: MachineStatus, isOn: Bool) {
      self.machineId = machineId
      self.name = name
      self.status = status
      self.isOn = isOn
    }

    public var isPending: Bool { status == .syncing }
  }

  nonisolated public static func machineStatus(_ row: MachineReadiness) -> MachineStatus {
    switch row.state {
    case "ready": return .ready(toolCount: row.toolCount)
    case "connecting": return .connecting
    case "idle": return .idle
    case "disabled": return .off
    default:
      let reason = row.reason ?? FleetRowStatus.blockedFallbackReason
      switch row.code {
      case "needsAuthorization", "expired": return .needsAuthorization(reason: reason)
      case "needsSetup", "unavailable": return .needsSetup(reason: reason)
      default: return .blocked(reason: reason)
      }
    }
  }

  nonisolated public static func isReportedOn(_ row: MachineReadiness) -> Bool {
    row.state != "disabled"
  }

  nonisolated public static func machineRows(
    name: String,
    readiness: [String: [MachineReadiness]],
    machines: [FleetMachineInfo],
    desiredOn: (FleetMachineInfo) -> Bool = { _ in true },
    intents: [String: Bool] = [:]
  ) -> [MachineRow] {
    machines.map { machine in
      let reported = machine.syncKey.flatMap { key in
        readiness[key]?.first { $0.name == name }
      }
      return machineRow(
        machine, reported: reported, desiredOn: desiredOn(machine), intent: intents[machine.id])
    }
  }

  nonisolated static func machineRow(
    _ machine: FleetMachineInfo, reported: MachineReadiness?, desiredOn: Bool, intent: Bool?
  ) -> MachineRow {
    let confirmedOn = reported.map(isReportedOn)
    let isOn = intent ?? confirmedOn ?? desiredOn
    let status: MachineStatus
    if !machine.isReachable {
      status = .unreachable
    } else if let intent, intent != confirmedOn {
      status = .syncing
    } else if let reported {
      status = machineStatus(reported)
    } else {
      status = desiredOn ? .syncing : .off
    }
    return MachineRow(machineId: machine.id, name: machine.name, status: status, isOn: isOn)
  }

  public static func overlayDisabledKeys(
    _ sync: ConfigSync, name: String, machines: [FleetMachineInfo]
  ) -> Set<String> {
    Set(
      machines.compactMap { machine in
        guard let key = machine.syncKey, isDisabled(sync, machineId: key, name: name) else {
          return nil
        }
        return key
      })
  }

  public static func fleetEnabled(_ sync: ConfigSync, name: String) -> Bool? {
    guard case .object(let value)? = sync.value(namespace: "mcps", key: name),
      case .bool(let enabled)? = value["enabled"]
    else { return nil }
    return enabled
  }
}
