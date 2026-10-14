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
}
