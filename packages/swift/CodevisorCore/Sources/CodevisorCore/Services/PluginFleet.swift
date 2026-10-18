import Foundation

@MainActor
public enum PluginFleet {
  public struct MachineReadiness: Identifiable, Equatable, Sendable {
    public let pluginId: String
    public let state: String
    public let reason: String?
    public var id: String { pluginId }

    public init(pluginId: String, state: String, reason: String?) {
      self.pluginId = pluginId
      self.state = state
      self.reason = reason
    }
  }

  public static func readiness(_ sync: ConfigSync) -> [String: [MachineReadiness]] {
    var result: [String: [MachineReadiness]] = [:]
    for entry in sync.entries(namespace: "plugin-readiness") where entry.deleted != true {
      guard case .object(let value) = entry.value,
        case .array(let plugins) = value["plugins"] ?? .null
      else { continue }
      result[entry.key] = plugins.compactMap { plugin in
        guard case .object(let fields) = plugin,
          case .string(let id) = fields["id"] ?? .null,
          case .string(let state) = fields["state"] ?? .null
        else { return nil }
        let reason: String? =
          if case .string(let text) = fields["reason"] ?? .null { text } else { nil }
        return MachineReadiness(pluginId: id, state: state, reason: reason)
      }
    }
    return result
  }

  public enum MachineStatus: Equatable, Sendable {
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

  nonisolated public static func machineStatus(state: String, reason: String?) -> MachineStatus {
    switch state {
    case "ready": .ready
    case "disabled": .off
    case "notInstalled": .installing
    case "blocked": .blocked(reason: reason ?? FleetRowStatus.blockedFallbackReason)
    case "machineOnly": .localOnly
    default: .syncing
    }
  }

  nonisolated public static func machineRows(
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

  public static func rows(
    pluginId: String, sync: ConfigSync, machines: [FleetMachineInfo]
  ) -> [MachineRow] {
    machineRows(
      pluginId: pluginId, readiness: readiness(sync), machines: machines,
      wantsOn: settings(sync).first { $0.id == pluginId }?.enabled ?? false)
  }

  public struct Setting: Identifiable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool
    public var source: String

    public init(id: String, enabled: Bool, source: String) {
      self.id = id
      self.enabled = enabled
      self.source = source
    }
  }

  public static func settings(_ sync: ConfigSync) -> [Setting] {
    _ = sync.revisionsByNamespace["plugins"]
    return sync.entries(namespace: "plugins").compactMap { entry in
      guard entry.deleted != true,
        case .object(let fields) = entry.value,
        case .bool(let enabled) = fields["enabled"] ?? .null,
        case .string(let source) = fields["source"] ?? .null
      else { return nil }
      return Setting(id: entry.key, enabled: enabled, source: source)
    }
  }

  public static func setEnabled(_ setting: Setting, enabled: Bool, in sync: ConfigSync) {
    sync.set(
      namespace: "plugins", key: setting.id,
      value: .object(["enabled": .bool(enabled), "source": .string(setting.source)]))
  }

  public static func remove(_ pluginId: String, in sync: ConfigSync) {
    sync.remove(namespace: "plugins", key: pluginId)
  }
}
