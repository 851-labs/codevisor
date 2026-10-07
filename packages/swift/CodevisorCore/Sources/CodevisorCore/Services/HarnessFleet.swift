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
    /// When the machine last published its readiness.
    public let reportedAt: Date?
    /// Display identity and whether sign-in applies; nil from servers that
    /// predate them.
    public let name: String?
    public let symbolName: String?
    public let authRequired: Bool?
    public var id: String { harnessId }

    /// The leading number of `version` ("2.0.24" → 2), when it has one.
    public var majorVersion: Int? {
      version.flatMap { Int($0.drop { $0 == "v" }.prefix { $0.isNumber }) }
    }

    public init(
      harnessId: String, state: String, reason: String?, installed: Bool? = nil, version: String? = nil,
      reportedAt: Date? = nil, name: String? = nil, symbolName: String? = nil, authRequired: Bool? = nil
    ) {
      self.name = name
      self.symbolName = symbolName
      self.authRequired = authRequired
      self.installed = installed
      self.version = version
      self.reportedAt = reportedAt
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
        let name: String? = if case .string(let value) = fields["name"], !value.isEmpty { value } else { nil }
        let symbolName: String? =
          if case .string(let value) = fields["symbolName"], !value.isEmpty { value } else { nil }
        let authRequired: Bool? = if case .bool(let value) = fields["authRequired"] { value } else { nil }
        return MachineReadiness(
          harnessId: id, state: state, reason: reason, installed: installed, version: version,
          reportedAt: entry.timestamp.date, name: name, symbolName: symbolName, authRequired: authRequired)
      }
    }
    return result
  }

  /// A harness some machine can run, as "Add Harness…" offers it.
  public struct CatalogEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let symbolName: String
    /// False only when a machine reported the harness needs no sign-in.
    public let authRequired: Bool
  }

  /// Every harness any machine reported, read from the synced readiness
  /// rows so offering one never waits on a machine. Rows from servers that
  /// predate display fields fall back to the fleet's authored row, then the
  /// registry.
  public static func catalog(_ sync: ConfigSync) -> [CatalogEntry] {
    var rowsById: [String: [MachineReadiness]] = [:]
    for row in readiness(sync).values.joined() { rowsById[row.harnessId, default: []].append(row) }
    let authored = Dictionary(
      settings(sync, includingUninstalled: true).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return rowsById.map { id, rows in
      let descriptor = HarnessRegistry.descriptor(for: id)
      return CatalogEntry(
        id: id,
        name: rows.lazy.compactMap(\.name).first ?? authored[id]?.name ?? descriptor.displayName,
        symbolName: rows.lazy.compactMap(\.symbolName).first ?? authored[id]?.symbolName ?? descriptor.symbolName,
        authRequired: !rows.contains { $0.authRequired == false })
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
