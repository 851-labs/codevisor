import Foundation

/// Phase 24: the client-side read of each machine's per-harness condition —
/// the REPORTED half of the desired-vs-reported matrix. One single-writer
/// "harness-readiness" entry per machine, mirroring McpFleet's shape.
@MainActor
public enum HarnessFleet {
  /// One harness's condition on one machine, as that machine reported it:
  /// ready | signInRequired | notInstalled | disabled.
  public struct MachineReadiness: Identifiable, Equatable, Sendable {
    public let harnessId: String
    public let state: String
    public let reason: String?
    public let installed: Bool?
    /// The installed CLI's version, as the machine reported it.
    public let version: String?
    public var id: String { harnessId }

    /// The leading number of `version` ("2.0.24" → 2), when it has one.
    public var majorVersion: Int? {
      version.flatMap { Int($0.drop { $0 == "v" }.prefix { $0.isNumber }) }
    }

    public init(harnessId: String, state: String, reason: String?, installed: Bool? = nil, version: String? = nil) {
      self.installed = installed
      self.version = version
      self.harnessId = harnessId
      self.state = state
      self.reason = reason
    }
  }

  /// machineId → that machine's readiness rows, parsed from the replica.
  public static func readiness(_ sync: ConfigSync) -> [String: [MachineReadiness]] {
    _ = sync.revisionsByNamespace["harness-readiness"]
    var result: [String: [MachineReadiness]] = [:]
    for entry in sync.entries(namespace: "harness-readiness") where entry.deleted != true {
      guard case .object(let value) = entry.value,
        case .array(let harnesses) = value["harnesses"] ?? .null
      else { continue }
      result[entry.key] = harnesses.compactMap { harness in
        guard case .object(let fields) = harness,
          case .string(let id) = fields["id"] ?? .null,
          case .string(let state) = fields["state"] ?? .null
        else { return nil }
        let reason: String? =
          if case .string(let text) = fields["reason"] ?? .null { text } else { nil }
        let installed: Bool? = if case .bool(let value) = fields["installed"] { value } else { nil }
        let version: String? = if case .string(let value) = fields["version"] { value } else { nil }
        return MachineReadiness(
          harnessId: id, state: state, reason: reason, installed: installed, version: version)
      }
    }
    return result
  }
}
