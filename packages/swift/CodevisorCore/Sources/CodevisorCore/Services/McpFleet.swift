import Foundation

@MainActor
public enum McpFleet {
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

  @discardableResult
  public static func disableLocally(
    _ sync: ConfigSync,
    machines: MachineController,
    name: String,
    timeout: Duration = .seconds(60)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while true {
      if let key = machines.syncKey(forMachineId: CodevisorMachine.local.id) {
        setDisabled(sync, machineId: key, name: name, disabled: true)
        return true
      }
      guard clock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(500))
    }
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

  public struct MachineRow: Identifiable, Equatable, Sendable {
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

  nonisolated public static func machineStatus(_ row: MachineReadiness) -> MachineStatus {
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

  nonisolated public static func machineRows(
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

  public static func rowsRespectingBuiltIns(
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

  public static func rows(
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
