import Foundation

/// Persists the composer choices a new chat was last created with — the
/// harness, that harness's config selections (model, reasoning effort, …), and
/// the worktree preference — so the next new chat starts from the same setup.
///
/// Captured once per session creation (first send), never per keystroke, so it
/// adds nothing to the composer's typing path.
@MainActor
public final class ComposerDefaultsStore {
    private struct Defaults: Codable {
        var lastHarnessId: String?
        var runInWorktree = false
        /// Config option selections keyed by harness id, then option id.
        /// Option ids and values are harness-specific, so each harness
        /// remembers its own model/reasoning picks.
        var configSelections: [String: [String: String]] = [:]
    }

    private let store: any PersistenceStore
    private let key: String
    private var defaults: Defaults

    public init(store: any PersistenceStore, key: String = "composer-defaults") {
        self.store = store
        self.key = key
        if let data = store.loadData(forKey: key),
           let decoded = try? JSONDecoder().decode(Defaults.self, from: data) {
            defaults = decoded
        } else {
            defaults = Defaults()
        }
    }

    /// The harness the last session was created with.
    public var lastHarnessId: String? { defaults.lastHarnessId }

    /// Whether the last session was created in a new worktree.
    public var runInWorktree: Bool { defaults.runInWorktree }

    /// The remembered config selections (option id → value) for a harness.
    public func configSelections(forHarness harnessId: String) -> [String: String] {
        defaults.configSelections[harnessId] ?? [:]
    }

    /// Records the choices a session was just created with.
    public func rememberSessionCreation(
        harnessId: String?,
        configValues: [String: String],
        runInWorktree: Bool
    ) {
        if let harnessId, !harnessId.isEmpty {
            defaults.lastHarnessId = harnessId
            defaults.configSelections[harnessId] = configValues
        }
        defaults.runInWorktree = runInWorktree
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
