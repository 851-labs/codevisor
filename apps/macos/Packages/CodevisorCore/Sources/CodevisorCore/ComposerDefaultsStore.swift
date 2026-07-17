import Foundation

/// Persists the composer choices a new chat was last created with — the
/// harness, that harness's config selections (model, reasoning effort, …), and
/// the worktree preference — so the next new chat starts from the same setup.
///
/// Captured once per session creation (first send), never per keystroke, so it
/// adds nothing to the composer's typing path.
@MainActor
public final class ComposerDefaultsStore {
    private struct MachineDefaults: Codable {
        var lastHarnessId: String?
        var runInWorktree = false
        /// Config option selections keyed by harness id, then option id.
        /// Option ids and values are harness-specific, so each harness
        /// remembers its own model/reasoning picks.
        var configSelections: [String: [String: String]] = [:]
    }

    private struct Defaults: Codable {
        var machines: [String: MachineDefaults] = [:]
    }

    /// The flat pre-machine-scoping payload ("Scope remote state by machine"
    /// restructured it). Decoded as a fallback so updating the app migrates
    /// the user's remembered choices instead of resetting them. All fields
    /// are optional so any partial legacy file still loads.
    private struct LegacyDefaults: Decodable {
        var lastHarnessId: String?
        var runInWorktree: Bool?
        var configSelections: [String: [String: String]]?

        var isEmpty: Bool {
            lastHarnessId == nil && runInWorktree == nil && configSelections == nil
        }
    }

    /// The only machine that existed before defaults were machine-scoped, so
    /// all legacy data belongs to it. Matches MachineController's local id.
    private static let legacyServerId = "local"

    private let store: any PersistenceStore
    private let key: String
    private var defaults: Defaults

    public init(store: any PersistenceStore, key: String = "composer-defaults") {
        self.store = store
        self.key = key
        guard let data = store.loadData(forKey: key) else {
            defaults = Defaults()
            return
        }
        let decoder = JSONDecoder()
        do {
            defaults = try decoder.decode(Defaults.self, from: data)
        } catch {
            if let legacy = try? decoder.decode(LegacyDefaults.self, from: data), !legacy.isEmpty {
                defaults = Defaults(machines: [
                    Self.legacyServerId: MachineDefaults(
                        lastHarnessId: legacy.lastHarnessId,
                        runInWorktree: legacy.runInWorktree ?? false,
                        configSelections: legacy.configSelections ?? [:]
                    )
                ])
                // Rewrite in the current schema so the fallback runs once.
                persist()
            } else {
                defaults = Defaults()
                handleCorruptPayload(store: store, key: key, data: data, error: error)
            }
        }
    }

    /// The harness the last session was created with.
    public func lastHarnessId(forServer serverId: String) -> String? {
        defaults.machines[serverId]?.lastHarnessId
    }

    /// Whether the last session was created in a new worktree.
    public func runInWorktree(forServer serverId: String) -> Bool {
        defaults.machines[serverId]?.runInWorktree ?? false
    }

    /// The remembered config selections (option id → value) for a harness.
    public func configSelections(forHarness harnessId: String, onServer serverId: String) -> [String: String] {
        defaults.machines[serverId]?.configSelections[harnessId] ?? [:]
    }

    /// Records the choices a session was just created with.
    public func rememberSessionCreation(
        serverId: String,
        harnessId: String?,
        configValues: [String: String],
        runInWorktree: Bool
    ) {
        var machine = defaults.machines[serverId] ?? MachineDefaults()
        if let harnessId, !harnessId.isEmpty {
            machine.lastHarnessId = harnessId
            machine.configSelections[harnessId] = configValues
        }
        machine.runInWorktree = runInWorktree
        defaults.machines[serverId] = machine
        persist()
    }

    /// Clears the remembered defaults (used by "Delete all data").
    public func clear() {
        defaults = Defaults()
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
