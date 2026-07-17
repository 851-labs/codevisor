import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("ComposerDefaultsStore")
struct ComposerDefaultsStoreTests {
    @Test("Starts empty")
    func startsEmpty() {
        let defaults = ComposerDefaultsStore(store: InMemoryStore())
        #expect(defaults.lastHarnessId(forServer: "local") == nil)
        #expect(defaults.runInWorktree(forServer: "local") == false)
        #expect(defaults.configSelections(forHarness: "claude-code", onServer: "local").isEmpty)
    }

    @Test("Remembers the choices a session was created with")
    func remembersCreationChoices() {
        let defaults = ComposerDefaultsStore(store: InMemoryStore())
        defaults.rememberSessionCreation(
            serverId: "local",
            harnessId: "claude-code",
            configValues: ["model": "opus", "thought_level": "high"],
            runInWorktree: true
        )
        #expect(defaults.lastHarnessId(forServer: "local") == "claude-code")
        #expect(defaults.runInWorktree(forServer: "local") == true)
        #expect(defaults.configSelections(forHarness: "claude-code", onServer: "local") == [
            "model": "opus", "thought_level": "high"
        ])
    }

    @Test("Keeps per-harness selections independent")
    func perHarnessSelections() {
        let defaults = ComposerDefaultsStore(store: InMemoryStore())
        defaults.rememberSessionCreation(
            serverId: "local", harnessId: "claude-code", configValues: ["model": "opus"], runInWorktree: false
        )
        defaults.rememberSessionCreation(
            serverId: "local", harnessId: "codex", configValues: ["model": "gpt-5.5"], runInWorktree: false
        )
        #expect(defaults.lastHarnessId(forServer: "local") == "codex")
        #expect(defaults.configSelections(forHarness: "claude-code", onServer: "local") == ["model": "opus"])
        #expect(defaults.configSelections(forHarness: "codex", onServer: "local") == ["model": "gpt-5.5"])
    }

    @Test("A nil or empty harness id keeps the previous harness defaults")
    func nilHarnessKeepsPrevious() {
        let defaults = ComposerDefaultsStore(store: InMemoryStore())
        defaults.rememberSessionCreation(
            serverId: "local", harnessId: "claude-code", configValues: ["model": "opus"], runInWorktree: true
        )
        defaults.rememberSessionCreation(serverId: "local", harnessId: nil, configValues: [:], runInWorktree: false)
        #expect(defaults.lastHarnessId(forServer: "local") == "claude-code")
        #expect(defaults.configSelections(forHarness: "claude-code", onServer: "local") == ["model": "opus"])
        // The worktree choice still updates — it isn't harness-scoped.
        #expect(defaults.runInWorktree(forServer: "local") == false)
    }

    @Test("Persists across instances")
    func persists() {
        let store = InMemoryStore()
        ComposerDefaultsStore(store: store).rememberSessionCreation(
            serverId: "local", harnessId: "codex", configValues: ["model": "gpt-5.5"], runInWorktree: true
        )
        let reopened = ComposerDefaultsStore(store: store)
        #expect(reopened.lastHarnessId(forServer: "local") == "codex")
        #expect(reopened.runInWorktree(forServer: "local") == true)
        #expect(reopened.configSelections(forHarness: "codex", onServer: "local") == ["model": "gpt-5.5"])
    }

    @Test("Clear resets everything")
    func clears() {
        let store = InMemoryStore()
        let defaults = ComposerDefaultsStore(store: store)
        defaults.rememberSessionCreation(
            serverId: "local", harnessId: "codex", configValues: ["model": "gpt-5.5"], runInWorktree: true
        )
        defaults.clear()
        #expect(defaults.lastHarnessId(forServer: "local") == nil)
        #expect(defaults.runInWorktree(forServer: "local") == false)
        #expect(defaults.configSelections(forHarness: "codex", onServer: "local").isEmpty)
        let reopened = ComposerDefaultsStore(store: store)
        #expect(reopened.lastHarnessId(forServer: "local") == nil)
    }

    @Test("Corrupted data decodes as empty and is quarantined, not overwritten")
    func corrupted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codevisor-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: directory.appendingPathComponent("composer-defaults.json"))

        let defaults = ComposerDefaultsStore(store: FileSystemStore(directory: directory))
        #expect(defaults.lastHarnessId(forServer: "local") == nil)
        #expect(defaults.runInWorktree(forServer: "local") == false)

        // The unreadable payload was renamed to a .corrupt-<timestamp> backup
        // so the next save can't destroy the only copy.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!contents.contains("composer-defaults.json"))
        #expect(contents.contains { $0.hasPrefix("composer-defaults.json.corrupt-") })
    }

    @Test("Migrates the pre-machine-scoping flat format to the local machine")
    func migratesLegacyFlatFormat() {
        let legacy = #"{"lastHarnessId":"claude-code","runInWorktree":true,"configSelections":{"claude-code":{"model":"opus","thought_level":"high","speed":"fast"}}}"#
        let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])
        let defaults = ComposerDefaultsStore(store: store)
        #expect(defaults.lastHarnessId(forServer: "local") == "claude-code")
        #expect(defaults.runInWorktree(forServer: "local") == true)
        #expect(defaults.configSelections(forHarness: "claude-code", onServer: "local") == [
            "model": "opus", "thought_level": "high", "speed": "fast"
        ])
        // The migration rewrites the file in the current, machine-scoped schema.
        let persisted = String(decoding: store.loadData(forKey: "composer-defaults") ?? Data(), as: UTF8.self)
        #expect(persisted.contains("\"machines\""))
    }

    @Test("Migrates a partial legacy payload with no remembered harness")
    func migratesPartialLegacyPayload() {
        let legacy = #"{"runInWorktree":true,"configSelections":{}}"#
        let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])
        let defaults = ComposerDefaultsStore(store: store)
        #expect(defaults.lastHarnessId(forServer: "local") == nil)
        #expect(defaults.runInWorktree(forServer: "local") == true)
    }

    /// ⚠️ Schema tripwire. If this test fails, you changed the persisted
    /// composer-defaults wire format. Shipping that as-is means every user's
    /// remembered model/thinking/speed choices fail to decode and silently
    /// reset on app update. Before updating the golden string below you must:
    /// 1. Keep a decode fallback for the CURRENT format in
    ///    `ComposerDefaultsStore.init` (see `LegacyDefaults` for the pattern)
    ///    that migrates old files into the new schema.
    /// 2. Add a migration test above (like `migratesLegacyFlatFormat`) proving
    ///    a file in the old format still loads with its data intact.
    /// Only skip the migration if the user has explicitly confirmed that
    /// losing everyone's remembered composer choices is intended.
    @Test("Persisted wire format is stable — schema changes require a migration")
    func wireFormatIsStable() throws {
        let store = InMemoryStore()
        let defaults = ComposerDefaultsStore(store: store)
        defaults.rememberSessionCreation(
            serverId: "local",
            harnessId: "claude-code",
            configValues: ["model": "opus", "thought_level": "high"],
            runInWorktree: true
        )
        let data = try #require(store.loadData(forKey: "composer-defaults"))
        let object = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(String(decoding: canonical, as: UTF8.self) == #"{"machines":{"local":{"configSelections":{"claude-code":{"model":"opus","thought_level":"high"}},"lastHarnessId":"claude-code","runInWorktree":true}}}"#)
    }

    @Test("Never shares composer choices between machines")
    func machineIsolation() {
        let store = InMemoryStore()
        let defaults = ComposerDefaultsStore(store: store)
        defaults.rememberSessionCreation(
            serverId: "remote-a", harnessId: "codex",
            configValues: ["model": "model-a"], runInWorktree: true
        )
        defaults.rememberSessionCreation(
            serverId: "remote-b", harnessId: "claude-code",
            configValues: ["model": "model-b"], runInWorktree: false
        )

        #expect(defaults.lastHarnessId(forServer: "remote-a") == "codex")
        #expect(defaults.lastHarnessId(forServer: "remote-b") == "claude-code")
        #expect(defaults.configSelections(forHarness: "codex", onServer: "remote-a") == ["model": "model-a"])
        #expect(defaults.configSelections(forHarness: "codex", onServer: "remote-b").isEmpty)
        #expect(defaults.runInWorktree(forServer: "remote-a"))
        #expect(!defaults.runInWorktree(forServer: "remote-b"))
    }
}
