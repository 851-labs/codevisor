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
        public var id: String { harnessId }

        public init(harnessId: String, state: String, reason: String?) {
            self.harnessId = harnessId
            self.state = state
            self.reason = reason
        }
    }

    /// machineId → that machine's readiness rows, parsed from the replica.
    public static func readiness(_ sync: ConfigSync) -> [String: [MachineReadiness]] {
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
                return MachineReadiness(harnessId: id, state: state, reason: reason)
            }
        }
        return result
    }
}
