import Foundation

/// The client-side view of the skills plane. Desired state is the "skills"
/// namespace — one entry per canonical skill, `{hash, name}`, where the hash
/// is the tree hash of the skill directory. Reported state is
/// "skill-readiness", one single-writer entry per machine, mirroring the
/// other three planes. Key shapes mirror apps/server/src/infra/skills-fleet.ts.
@MainActor
public enum SkillFleet {
  /// One skill's condition on one machine, as that machine reported it.
  public struct MachineReadiness: Identifiable, Equatable, Sendable {
    public let directoryName: String
    public let state: String
    public let reason: String?
    public var id: String { directoryName }

    public init(directoryName: String, state: String, reason: String?) {
      self.directoryName = directoryName
      self.state = state
      self.reason = reason
    }
  }

  /// machineId → that machine's readiness rows, parsed from the replica.
  public static func readiness(_ sync: ConfigSync) -> [String: [MachineReadiness]] {
    _ = sync.revisionsByNamespace["skill-readiness"]
    var result: [String: [MachineReadiness]] = [:]
    for entry in sync.entries(namespace: "skill-readiness") where entry.deleted != true {
      guard case .object(let value) = entry.value,
        case .array(let skills) = value["skills"] ?? .null
      else { continue }
      result[entry.key] = skills.compactMap { skill in
        guard case .object(let fields) = skill,
          case .string(let directoryName) = fields["directoryName"] ?? .null,
          case .string(let state) = fields["state"] ?? .null
        else { return nil }
        let reason: String? =
          if case .string(let text) = fields["reason"] ?? .null { text } else { nil }
        return MachineReadiness(directoryName: directoryName, state: state, reason: reason)
      }
    }
    return result
  }

  /// One skill the fleet carries. Skills have no enabled flag: a skill is
  /// either in the canonical store or it isn't, so the row has no toggle.
  public struct Setting: Identifiable, Equatable, Sendable {
    public var directoryName: String
    public var name: String
    public var id: String { directoryName }

    public init(directoryName: String, name: String) {
      self.directoryName = directoryName
      self.name = name
    }
  }

  public static func settings(_ sync: ConfigSync) -> [Setting] {
    _ = sync.revisionsByNamespace["skills"]
    return sync.entries(namespace: "skills")
      .compactMap { entry in
        guard entry.deleted != true, case .object(let fields) = entry.value else { return nil }
        let name: String =
          if case .string(let value) = fields["name"] ?? .null, !value.isEmpty {
            value
          } else {
            entry.key
          }
        return Setting(directoryName: entry.key, name: name)
      }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
