import Foundation

/// Phase 18: the client-side view of the MCP plane's per-machine data.
/// Read side: "mcp-readiness" (one single-writer entry per machine, listing
/// every MCP's live state THERE). Write side: "mcp-overlays" per-machine
/// disable entries — plain LWW writes that gossip like any other config.
/// Key shapes mirror apps/server/src/infra/mcp-fleet.ts exactly.
@MainActor
public enum McpFleet {
  /// One MCP's condition on one machine, as that machine reported it.
  public struct MachineReadiness: Identifiable, Equatable, Sendable {
    public let name: String
    public let state: String
    public let reason: String?
    public var id: String { name }
  }

  /// machineId → that machine's readiness rows, parsed from the replica.
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
        return MachineReadiness(name: name, state: state, reason: reason)
      }
    }
    return result
  }

  static func disableKey(machineId: String, name: String) -> String {
    "enable|\(machineId)|\(name)"
  }

  /// True when a live overlay disables `name` on `machineId`.
  public static func isDisabled(_ sync: ConfigSync, machineId: String, name: String) -> Bool {
    guard
      case .object(let value)? = sync.value(
        namespace: "mcp-overlays",
        key: disableKey(machineId: machineId, name: name)
      )
    else { return false }
    return value["enabled"] == .bool(false)
  }

  /// Disables `name` on THIS machine — the per-machine escape hatch the
  /// permission-skip flows use. Never touches the fleet definition. The
  /// local server's sync key is only known once its /v1/info probe has
  /// answered, so this waits (bounded) for it rather than writing under a
  /// placeholder id every app-hosted machine would share. False when the
  /// server never identified itself in time; `reconcileSkippedPermissions`
  /// heals that on the next launch.
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

  /// Flips the per-machine disable overlay. Restoring deletes the entry
  /// (a tombstone), so "no overlay" stays the fleet's normal state.
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
