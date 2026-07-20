import Foundation

/// Persists explicit composer selections for the next new chat. Harness and
/// run-location choices are remembered per machine, while
/// model/reasoning/speed values are remembered independently for every harness
/// on that machine.
///
/// Picker actions update this store immediately. Session creation is not a
/// persistence boundary: abandoning an unsent chat does not undo an explicit
/// selection, and every subsequent composer starts from the last thing the
/// user picked.
@MainActor
public final class ComposerDefaultsStore {
    nonisolated private static let schemaVersion = 3
    nonisolated private static let legacyServerId = "local"

    public enum RunLocation: String, Codable, Sendable {
        case projectDirectory
        case newWorktree
    }

    private struct MachineDefaults: Codable {
        var lastHarnessId: String?
        /// Existing worktree paths are deliberately not remembered: they are
        /// scoped to one project/draft and can disappear independently.
        var lastRunLocation: RunLocation?
        /// Config option selections keyed by harness id, then option id.
        /// Keeping every harness here is important: changing harnesses should
        /// restore that harness's own model/reasoning/speed selections.
        var configSelections: [String: [String: String]] = [:]
    }

    private struct Defaults: Codable {
        var version = ComposerDefaultsStore.schemaVersion
        var machines: [String: MachineDefaults] = [:]
    }

    /// The schema shipped immediately before V3. Workspace values were
    /// snapshots written alongside the machine value; the machine layer is
    /// therefore already the correct global last-used value. Decode the whole
    /// shape explicitly so an update never mistakes it for corrupt data.
    private struct ScopedDefaultsV2: Decodable {
        var machines: [String: MachineDefaultsV2]
        var workspaces: [String: WorkspaceDefaultsV2]?
    }

    private struct MachineDefaultsV2: Decodable {
        var lastHarnessId: String?
        var runInWorktree: Bool?
        var configSelections: [String: [String: String]]?
    }

    private struct WorkspaceDefaultsV2: Decodable {
        var lastHarnessId: String?
        var configSelections: [String: [String: String]]?
    }

    /// The flat pre-machine-scoping payload. All fields remain optional so a
    /// partial legacy file still migrates rather than being quarantined.
    private struct FlatDefaultsV1: Decodable {
        var lastHarnessId: String?
        var runInWorktree: Bool?
        var configSelections: [String: [String: String]]?

        var isRecognized: Bool {
            lastHarnessId != nil || runInWorktree != nil || configSelections != nil
        }
    }

    private let store: any PersistenceStore
    private let key: String
    private let migrationBackupKey: String
    private var defaults: Defaults

    public init(store: any PersistenceStore, key: String = "composer-defaults") {
        self.store = store
        self.key = key
        migrationBackupKey = "\(key)-pre-v3-backup"
        guard let data = store.loadData(forKey: key) else {
            defaults = Defaults()
            return
        }

        let decoder = JSONDecoder()
        if let current = try? decoder.decode(Defaults.self, from: data),
           current.version == Self.schemaVersion {
            defaults = current
            recoverRunLocationsFromMigrationBackup(using: decoder)
            return
        }

        if let scoped = try? decoder.decode(ScopedDefaultsV2.self, from: data) {
            defaults = Defaults(
                machines: scoped.machines.mapValues { machine in
                    MachineDefaults(
                        lastHarnessId: machine.lastHarnessId,
                        lastRunLocation: machine.runInWorktree.map {
                            $0 ? .newWorktree : .projectDirectory
                        },
                        configSelections: machine.configSelections ?? [:]
                    )
                }
            )
            backupAndPersistMigratedPayload(data)
            return
        }

        if let flat = try? decoder.decode(FlatDefaultsV1.self, from: data), flat.isRecognized {
            defaults = Defaults(machines: [
                Self.legacyServerId: MachineDefaults(
                    lastHarnessId: flat.lastHarnessId,
                    lastRunLocation: flat.runInWorktree.map {
                        $0 ? .newWorktree : .projectDirectory
                    },
                    configSelections: flat.configSelections ?? [:]
                )
            ])
            backupAndPersistMigratedPayload(data)
            return
        }

        defaults = Defaults()
        let error = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Unrecognized composer defaults payload")
        )
        handleCorruptPayload(store: store, key: key, data: data, error: error)
    }

    /// The harness most recently selected in a composer on this machine.
    public func lastHarnessId(forServer serverId: String) -> String? {
        defaults.machines[serverId]?.lastHarnessId
    }

    /// The project-directory/new-worktree choice most recently made in a
    /// composer on this machine. Nil means the user has not chosen one yet.
    public func runLocation(forServer serverId: String) -> RunLocation? {
        defaults.machines[serverId]?.lastRunLocation
    }

    /// The remembered option ids and values for one harness on this machine.
    public func configSelections(
        forHarness harnessId: String,
        onServer serverId: String
    ) -> [String: String] {
        defaults.machines[serverId]?.configSelections[harnessId] ?? [:]
    }

    /// Records an explicit harness picker action immediately.
    public func rememberHarnessSelection(serverId: String, harnessId: String?) {
        guard let harnessId, !harnessId.isEmpty else { return }
        var machine = defaults.machines[serverId] ?? MachineDefaults()
        machine.lastHarnessId = harnessId
        defaults.machines[serverId] = machine
        persist()
    }

    /// Records an explicit run-location picker action immediately.
    public func rememberRunLocationSelection(serverId: String, runLocation: RunLocation) {
        var machine = defaults.machines[serverId] ?? MachineDefaults()
        machine.lastRunLocation = runLocation
        defaults.machines[serverId] = machine
        persist()
    }

    /// Merges the latest known model/reasoning/speed values for one harness.
    /// Missing ids are retained because some options (notably speed) disappear
    /// temporarily when the selected model does not support them.
    public func rememberConfigSelections(
        serverId: String,
        harnessId: String?,
        configValues: [String: String]
    ) {
        guard let harnessId, !harnessId.isEmpty, !configValues.isEmpty else { return }
        var machine = defaults.machines[serverId] ?? MachineDefaults()
        var selections = machine.configSelections[harnessId] ?? [:]
        selections.merge(configValues) { _, latest in latest }
        machine.configSelections[harnessId] = selections
        defaults.machines[serverId] = machine
        persist()
    }

    /// Clears remembered selections and the migration safety copy (used by
    /// "Delete all data").
    public func clear() {
        defaults = Defaults()
        do {
            try store.removeData(forKey: migrationBackupKey)
        } catch {
            Log.persistence.error("Failed to remove \(self.migrationBackupKey, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        persist()
    }

    private func backupAndPersistMigratedPayload(_ data: Data) {
        if store.loadData(forKey: migrationBackupKey) == nil {
            do {
                try store.saveData(data, forKey: migrationBackupKey)
            } catch {
                Log.persistence.error("Failed to back up \(self.key, privacy: .public) before migration: \(String(describing: error), privacy: .public)")
            }
        }
        persist()
    }

    /// Early V3 builds removed `runInWorktree` before the sticky replacement
    /// was added. Recover just that field from the one-time migration backup,
    /// without replacing newer harness or config selections.
    private func recoverRunLocationsFromMigrationBackup(using decoder: JSONDecoder) {
        guard let backup = store.loadData(forKey: migrationBackupKey) else { return }
        var changed = false

        if let scoped = try? decoder.decode(ScopedDefaultsV2.self, from: backup) {
            for (serverId, legacy) in scoped.machines {
                guard defaults.machines[serverId]?.lastRunLocation == nil,
                      let runInWorktree = legacy.runInWorktree else { continue }
                var machine = defaults.machines[serverId] ?? MachineDefaults()
                machine.lastRunLocation = runInWorktree ? .newWorktree : .projectDirectory
                defaults.machines[serverId] = machine
                changed = true
            }
        } else if let flat = try? decoder.decode(FlatDefaultsV1.self, from: backup),
                  let runInWorktree = flat.runInWorktree,
                  defaults.machines[Self.legacyServerId]?.lastRunLocation == nil {
            var machine = defaults.machines[Self.legacyServerId] ?? MachineDefaults()
            machine.lastRunLocation = runInWorktree ? .newWorktree : .projectDirectory
            defaults.machines[Self.legacyServerId] = machine
            changed = true
        }

        if changed { persist() }
    }

    private func persist() {
        do {
            try store.saveData(JSONEncoder().encode(defaults), forKey: key)
        } catch {
            Log.persistence.error("Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
