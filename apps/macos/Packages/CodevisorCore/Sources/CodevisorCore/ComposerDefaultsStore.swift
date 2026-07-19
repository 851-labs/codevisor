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

    /// The composer choices last used INSIDE one workspace. New chats in
    /// that workspace start from these; the machine-level defaults are the
    /// fallback for brand-new workspaces.
    private struct WorkspaceDefaults: Codable {
        var lastHarnessId: String?
        var configSelections: [String: [String: String]] = [:]
    }

    private struct Defaults: Codable {
        var machines: [String: MachineDefaults] = [:]
        var workspaces: [String: WorkspaceDefaults] = [:]

        init(machines: [String: MachineDefaults] = [:]) {
            self.machines = machines
        }

        // Explicit decode: payloads written before workspace scoping have no
        // `workspaces` key and must keep loading (schema migration). A
        // payload with NEITHER key is the pre-machine-scoping flat format —
        // throw so init's `LegacyDefaults` fallback migrates it instead of
        // this decode silently succeeding as empty.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let machines = try container.decodeIfPresent(
                [String: MachineDefaults].self, forKey: .machines
            )
            let workspaces = try container.decodeIfPresent(
                [String: WorkspaceDefaults].self, forKey: .workspaces
            )
            guard machines != nil || workspaces != nil else {
                throw DecodingError.keyNotFound(
                    CodingKeys.machines,
                    .init(codingPath: [], debugDescription: "flat legacy payload")
                )
            }
            self.machines = machines ?? [:]
            self.workspaces = workspaces ?? [:]
        }
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

    /// The harness the last session was created with — scoped to the
    /// workspace when it has its own history, falling back to the machine.
    public func lastHarnessId(forWorkspace workspaceId: UUID?, orServer serverId: String) -> String? {
        if let workspaceId,
           let scoped = defaults.workspaces[workspaceId.uuidString]?.lastHarnessId {
            return scoped
        }
        return defaults.machines[serverId]?.lastHarnessId
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

    /// Workspace-scoped config selections, falling back to the machine's:
    /// a new chat in a workspace repeats what was last used THERE; a chat
    /// in a fresh workspace repeats what was last used anywhere.
    public func configSelections(
        forHarness harnessId: String,
        workspace workspaceId: UUID?,
        orServer serverId: String
    ) -> [String: String] {
        if let workspaceId,
           let scoped = defaults.workspaces[workspaceId.uuidString]?.configSelections[harnessId],
           !scoped.isEmpty {
            return scoped
        }
        return configSelections(forHarness: harnessId, onServer: serverId)
    }

    /// Records the choices a session was just created with: the machine
    /// level (the app-wide "last used" fallback) and, when known, the
    /// workspace level.
    public func rememberSessionCreation(
        serverId: String,
        workspaceId: UUID? = nil,
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
        rememberWorkspaceSelections(
            workspaceId: workspaceId, harnessId: harnessId, configValues: configValues
        )
        persist()
    }

    /// Records a mid-session settings change (model/reasoning/speed picked
    /// while chatting) so "last used" tracks what the user actually set
    /// last, not only what sessions were created with.
    public func rememberConfigSelections(
        serverId: String,
        workspaceId: UUID?,
        harnessId: String?,
        configValues: [String: String]
    ) {
        guard let harnessId, !harnessId.isEmpty, !configValues.isEmpty else { return }
        var machine = defaults.machines[serverId] ?? MachineDefaults()
        machine.lastHarnessId = harnessId
        machine.configSelections[harnessId] = configValues
        defaults.machines[serverId] = machine
        rememberWorkspaceSelections(
            workspaceId: workspaceId, harnessId: harnessId, configValues: configValues
        )
        persist()
    }

    private func rememberWorkspaceSelections(
        workspaceId: UUID?,
        harnessId: String?,
        configValues: [String: String]
    ) {
        guard let workspaceId, let harnessId, !harnessId.isEmpty else { return }
        var workspace = defaults.workspaces[workspaceId.uuidString] ?? WorkspaceDefaults()
        workspace.lastHarnessId = harnessId
        workspace.configSelections[harnessId] = configValues
        defaults.workspaces[workspaceId.uuidString] = workspace
        // Callers persist; this only mutates in-memory state.
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
