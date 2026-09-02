import Foundation

/// Phase 24: each machine's reported per-plugin condition — the third
/// readiness plane, mirroring McpFleet and HarnessFleet. States: ready |
/// disabled | notInstalled | blocked | machineOnly (linked/dev and
/// local-path plugins never sync, and say so).
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

  /// machineId → that machine's readiness rows, parsed from the replica.
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
}
