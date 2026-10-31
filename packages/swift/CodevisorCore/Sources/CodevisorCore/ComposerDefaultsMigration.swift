import Foundation

enum ComposerDefaultsMigration {
  private static let legacyServerId = "local"

  typealias HarnessSelections = [String: [String: String]]

  static func version(of data: Data, using decoder: JSONDecoder) -> Int? {
    (try? decoder.decode(VersionedPayload.self, from: data))?.version
  }

  static func decodeLegacy(_ data: Data, using decoder: JSONDecoder) -> ComposerDefaults? {
    let legacy =
      decodeV4ToV6(data, using: decoder)
      ?? decodeV3(data, using: decoder)
      ?? decodeV2(data, using: decoder)
      ?? decodeV1(data, using: decoder)
    return legacy?.migrated
  }

  private static func decodeV4ToV6(_ data: Data, using decoder: JSONDecoder) -> LegacyDefaults? {
    guard let scoped = try? decoder.decode(DefaultsV4ToV6.self, from: data),
      let version = scoped.version, (4...6).contains(version),
      let selections = try? decoder.decode(MachineSelectionsPayload.self, from: data)
    else { return nil }
    return LegacyDefaults(
      lastNewWorkspaceServerId: scoped.lastNewWorkspaceServerId,
      machines: scoped.machines,
      configSelections: selections.machines.mapValues { $0.configSelections ?? [:] }
    )
  }

  private static func decodeV3(_ data: Data, using decoder: JSONDecoder) -> LegacyDefaults? {
    guard let version3 = try? decoder.decode(DefaultsV3.self, from: data), version3.version == 3
    else { return nil }
    return LegacyDefaults(
      machines: version3.machines.mapValues { machine in
        ComposerDefaults.Machine(
          lastHarnessId: machine.lastHarnessId,
          newWorkspaceInWorktree: machine.newWorkspaceInWorktree
        )
      },
      configSelections: version3.machines.mapValues { $0.configSelections ?? [:] }
    )
  }

  private static func decodeV2(_ data: Data, using decoder: JSONDecoder) -> LegacyDefaults? {
    guard let scoped = try? decoder.decode(ScopedDefaultsV2.self, from: data) else { return nil }
    return LegacyDefaults(
      machines: scoped.machines.mapValues { ComposerDefaults.Machine(lastHarnessId: $0.lastHarnessId) },
      configSelections: scoped.machines.mapValues { $0.configSelections ?? [:] }
    )
  }

  private static func decodeV1(_ data: Data, using decoder: JSONDecoder) -> LegacyDefaults? {
    guard let flat = try? decoder.decode(FlatDefaultsV1.self, from: data), flat.isRecognized
    else { return nil }
    return LegacyDefaults(
      machines: [legacyServerId: ComposerDefaults.Machine(lastHarnessId: flat.lastHarnessId)],
      configSelections: [legacyServerId: flat.configSelections ?? [:]]
    )
  }

  private struct LegacyDefaults {
    var lastNewWorkspaceServerId: String?
    var machines: [String: ComposerDefaults.Machine]
    var configSelections: [String: HarnessSelections]

    var migrated: ComposerDefaults {
      ComposerDefaults(
        lastNewWorkspaceServerId: lastNewWorkspaceServerId,
        machines: machines,
        harnesses: mergedHarnesses
      )
    }

    private var serverIdsByRecency: [String] {
      let others = configSelections.keys.filter { $0 != lastNewWorkspaceServerId }.sorted()
      guard let lastNewWorkspaceServerId else { return others }
      return [lastNewWorkspaceServerId] + others
    }

    private var mergedHarnesses: [String: ComposerHarnessDefaults] {
      var merged: [String: ComposerHarnessDefaults] = [:]
      for serverId in serverIdsByRecency {
        for (harnessId, selections) in configSelections[serverId] ?? [:] {
          merged[harnessId, default: ComposerHarnessDefaults()]
            .fillGaps(from: ComposerHarnessDefaults(legacySelections: selections))
        }
      }
      return merged
    }
  }

  private struct VersionedPayload: Decodable {
    var version: Int?
  }

  private struct DefaultsV4ToV6: Decodable {
    var version: Int?
    var lastNewWorkspaceServerId: String?
    var machines: [String: ComposerDefaults.Machine]
  }

  private struct MachineSelectionsPayload: Decodable {
    var machines: [String: MachineSelections]
  }

  private struct MachineSelections: Decodable {
    var configSelections: HarnessSelections?
  }

  private struct DefaultsV3: Decodable {
    var version: Int?
    var machines: [String: MachineDefaultsV3]
  }

  private struct MachineDefaultsV3: Decodable {
    var lastHarnessId: String?
    var newWorkspaceInWorktree: Bool?
    var configSelections: HarnessSelections?
  }

  private struct ScopedDefaultsV2: Decodable {
    var machines: [String: MachineDefaultsV2]
  }

  private struct MachineDefaultsV2: Decodable {
    var lastHarnessId: String?
    var runInWorktree: Bool?
    var configSelections: HarnessSelections?
  }

  private struct FlatDefaultsV1: Decodable {
    var lastHarnessId: String?
    var runInWorktree: Bool?
    var configSelections: HarnessSelections?

    var isRecognized: Bool {
      lastHarnessId != nil || runInWorktree != nil || configSelections != nil
    }
  }
}
