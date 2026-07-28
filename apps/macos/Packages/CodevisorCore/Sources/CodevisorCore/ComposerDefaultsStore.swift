import Foundation

/// Persists explicit composer and workspace-creation selections. The harness
/// choice and the new-workspace worktree preference are remembered per
/// machine, while model/reasoning/speed values are remembered independently
/// for every harness on that machine.
///
/// Picker actions update this store immediately. Session creation is not a
/// persistence boundary: abandoning an unsent chat does not undo an explicit
/// selection, and every subsequent composer starts from the last thing the
/// user picked.
@MainActor
public final class ComposerDefaultsStore {
    nonisolated private static let schemaVersion = 3
    nonisolated private static let legacyServerId = "local"

    private struct MachineDefaults: Codable {
        var lastHarnessId: String?
        /// Whether the last workspace created on this machine used a fresh
        /// git worktree — seeds the New Workspace form's toggle.
        var newWorkspaceInWorktree: Bool?
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
        /// Legacy field, decode-only: run location is no longer remembered.
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
            return
        }

        if let scoped = try? decoder.decode(ScopedDefaultsV2.self, from: data) {
            defaults = Defaults(
                machines: scoped.machines.mapValues { machine in
                    MachineDefaults(
                        lastHarnessId: machine.lastHarnessId,
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

    /// Whether the last workspace created on this machine used a fresh git
    /// worktree. Seeds the New Workspace form's toggle; false until a
    /// workspace has been created.
    public func prefersWorktreeForNewWorkspaces(forServer serverId: String) -> Bool {
        defaults.machines[serverId]?.newWorkspaceInWorktree ?? false
    }

    /// Records the worktree choice a workspace was created with, so the next
    /// New Workspace form starts from it — same policy as the last-used
    /// harness.
    public func rememberNewWorkspaceWorktreePreference(
        serverId: String,
        createsWorktree: Bool
    ) {
        var machine = defaults.machines[serverId] ?? MachineDefaults()
        machine.newWorkspaceInWorktree = createsWorktree
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

    private func persist() {
        do {
            try store.saveData(JSONEncoder().encode(defaults), forKey: key)
        } catch {
            Log.persistence.error("Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
