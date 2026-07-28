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
        #expect(defaults.configSelections(forHarness: "claude-code", onServer: "local").isEmpty)
    }

    @Test("An explicit harness selection is remembered immediately")
    func remembersHarnessImmediately() {
        let store = InMemoryStore()
        let defaults = ComposerDefaultsStore(store: store)

        defaults.rememberHarnessSelection(serverId: "local", harnessId: "claude-code")

        #expect(defaults.lastHarnessId(forServer: "local") == "claude-code")
        #expect(ComposerDefaultsStore(store: store).lastHarnessId(forServer: "local") == "claude-code")
    }

    @Test("The new-workspace worktree choice is remembered per machine")
    func remembersWorkspaceWorktreePreference() {
        let store = InMemoryStore()
        let defaults = ComposerDefaultsStore(store: store)
        #expect(!defaults.prefersWorktreeForNewWorkspaces(forServer: "local"))

        defaults.rememberNewWorkspaceWorktreePreference(serverId: "local", createsWorktree: true)

        #expect(defaults.prefersWorktreeForNewWorkspaces(forServer: "local"))
        #expect(!defaults.prefersWorktreeForNewWorkspaces(forServer: "remote-a"))
        // Survives a reload, and an explicit project-folder choice wins later.
        #expect(ComposerDefaultsStore(store: store).prefersWorktreeForNewWorkspaces(forServer: "local"))
        defaults.rememberNewWorkspaceWorktreePreference(serverId: "local", createsWorktree: false)
        #expect(!defaults.prefersWorktreeForNewWorkspaces(forServer: "local"))
    }

    @Test("Keeps every harness configuration independent")
    func perHarnessSelections() {
        let defaults = ComposerDefaultsStore(store: InMemoryStore())
        defaults.rememberConfigSelections(
            serverId: "local",
            harnessId: "claude-code",
            configValues: ["model": "opus", "effort": "high", "speed": "fast"]
        )
        defaults.rememberConfigSelections(
            serverId: "local",
            harnessId: "codex",
            configValues: ["model": "gpt-5.6", "effort": "xhigh", "speed": "standard"]
        )

        #expect(defaults.configSelections(forHarness: "claude-code", onServer: "local") == [
            "model": "opus", "effort": "high", "speed": "fast"
        ])
        #expect(defaults.configSelections(forHarness: "codex", onServer: "local") == [
            "model": "gpt-5.6", "effort": "xhigh", "speed": "standard"
        ])
    }

    @Test("Partial option updates retain temporarily unavailable values")
    func mergesConfigSelections() {
        let defaults = ComposerDefaultsStore(store: InMemoryStore())
        defaults.rememberConfigSelections(
            serverId: "local",
            harnessId: "codex",
            configValues: ["model": "gpt-5.6", "effort": "high", "speed": "fast"]
        )
        // A model without a speed picker reports only its currently available
        // values. The prior speed preference should still be there if the user
        // switches back to a fast-capable model later.
        defaults.rememberConfigSelections(
            serverId: "local",
            harnessId: "codex",
            configValues: ["model": "gpt-5.5", "effort": "medium"]
        )

        #expect(defaults.configSelections(forHarness: "codex", onServer: "local") == [
            "model": "gpt-5.5", "effort": "medium", "speed": "fast"
        ])
    }

    @Test("Invalid empty selections do not erase existing defaults")
    func ignoresEmptySelections() {
        let defaults = ComposerDefaultsStore(store: InMemoryStore())
        defaults.rememberHarnessSelection(serverId: "local", harnessId: "claude-code")
        defaults.rememberConfigSelections(
            serverId: "local", harnessId: "claude-code", configValues: ["model": "opus"]
        )

        defaults.rememberHarnessSelection(serverId: "local", harnessId: nil)
        defaults.rememberHarnessSelection(serverId: "local", harnessId: "")
        defaults.rememberConfigSelections(
            serverId: "local", harnessId: "claude-code", configValues: [:]
        )

        #expect(defaults.lastHarnessId(forServer: "local") == "claude-code")
        #expect(defaults.configSelections(forHarness: "claude-code", onServer: "local") == [
            "model": "opus"
        ])
    }

    @Test("Migrates scoped V2 data without losing any harness configuration")
    func migratesScopedV2() throws {
        let legacy = #"{"machines":{"local":{"lastHarnessId":"claude-code","runInWorktree":true,"configSelections":{"claude-code":{"model":"opus","effort":"high","speed":"fast"},"codex":{"model":"gpt-5.6","effort":"xhigh","speed":"standard"}}},"remote-a":{"lastHarnessId":"codex","runInWorktree":false,"configSelections":{"codex":{"model":"remote-model","effort":"medium"}}}},"workspaces":{"00000000-0000-0000-0000-000000000001":{"lastHarnessId":"codex","configSelections":{"codex":{"model":"older-workspace-model","speed":"fast"}}}}}"#
        let legacyData = Data(legacy.utf8)
        let store = InMemoryStore(storage: ["composer-defaults": legacyData])

        let defaults = ComposerDefaultsStore(store: store)

        #expect(defaults.lastHarnessId(forServer: "local") == "claude-code")
        #expect(defaults.configSelections(forHarness: "claude-code", onServer: "local") == [
            "model": "opus", "effort": "high", "speed": "fast"
        ])
        #expect(defaults.configSelections(forHarness: "codex", onServer: "local") == [
            "model": "gpt-5.6", "effort": "xhigh", "speed": "standard"
        ])
        #expect(defaults.configSelections(forHarness: "codex", onServer: "remote-a") == [
            "model": "remote-model", "effort": "medium"
        ])
        #expect(store.loadData(forKey: "composer-defaults-pre-v3-backup") == legacyData)

        let migrated = try #require(store.loadData(forKey: "composer-defaults"))
        let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        #expect(object["version"] as? Int == 3)
        #expect(object["workspaces"] == nil)
        let machines = try #require(object["machines"] as? [String: Any])
        let local = try #require(machines["local"] as? [String: Any])
        #expect(local["runInWorktree"] == nil)
    }

    @Test("A V2 migration is idempotent and keeps its original backup")
    func migrationIsIdempotent() {
        let legacy = #"{"machines":{"local":{"lastHarnessId":"codex","runInWorktree":false,"configSelections":{"codex":{"model":"gpt-5.6"}}}},"workspaces":{}}"#
        let legacyData = Data(legacy.utf8)
        let store = InMemoryStore(storage: ["composer-defaults": legacyData])

        _ = ComposerDefaultsStore(store: store)
        let migrated = store.loadData(forKey: "composer-defaults")
        _ = ComposerDefaultsStore(store: store)

        #expect(store.loadData(forKey: "composer-defaults") == migrated)
        #expect(store.loadData(forKey: "composer-defaults-pre-v3-backup") == legacyData)
    }

    @Test("A V3 payload with the retired lastRunLocation field still decodes")
    func decodesRetiredRunLocationField() {
        let current = #"{"machines":{"local":{"lastHarnessId":"codex","lastRunLocation":"newWorktree","configSelections":{"codex":{"model":"newer-model"}}}},"version":3}"#
        let store = InMemoryStore(storage: ["composer-defaults": Data(current.utf8)])

        let defaults = ComposerDefaultsStore(store: store)

        #expect(defaults.lastHarnessId(forServer: "local") == "codex")
        #expect(defaults.configSelections(forHarness: "codex", onServer: "local") == [
            "model": "newer-model"
        ])
    }

    @Test("Migrates the pre-workspace machines-only format")
    func migratesMachinesOnlyFormat() {
        let legacy = #"{"machines":{"local":{"lastHarnessId":"claude-code","runInWorktree":true,"configSelections":{"claude-code":{"model":"opus","speed":"fast"}}}}}"#
        let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])

        let defaults = ComposerDefaultsStore(store: store)

        #expect(defaults.lastHarnessId(forServer: "local") == "claude-code")
        #expect(defaults.configSelections(forHarness: "claude-code", onServer: "local") == [
            "model": "opus", "speed": "fast"
        ])
    }

    @Test("Migrates the flat pre-machine format to the local machine")
    func migratesFlatFormat() {
        let legacy = #"{"lastHarnessId":"claude-code","runInWorktree":true,"configSelections":{"claude-code":{"model":"opus","effort":"high","speed":"fast"},"codex":{"model":"gpt-5.6"}}}"#
        let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])

        let defaults = ComposerDefaultsStore(store: store)

        #expect(defaults.lastHarnessId(forServer: "local") == "claude-code")
        #expect(defaults.configSelections(forHarness: "claude-code", onServer: "local") == [
            "model": "opus", "effort": "high", "speed": "fast"
        ])
        #expect(defaults.configSelections(forHarness: "codex", onServer: "local") == [
            "model": "gpt-5.6"
        ])
    }

    @Test("Migrates a partial flat payload that only remembered run location")
    func migratesPartialFlatPayload() throws {
        let legacy = #"{"runInWorktree":true}"#
        let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])

        let defaults = ComposerDefaultsStore(store: store)

        #expect(defaults.lastHarnessId(forServer: "local") == nil)
        let migrated = try #require(store.loadData(forKey: "composer-defaults"))
        let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        #expect(object["version"] as? Int == 3)
    }

    @Test("Persists the V3 format across instances without creating a migration backup")
    func persistsCurrentFormat() {
        let store = InMemoryStore()
        let defaults = ComposerDefaultsStore(store: store)
        defaults.rememberHarnessSelection(serverId: "local", harnessId: "codex")
        defaults.rememberConfigSelections(
            serverId: "local",
            harnessId: "codex",
            configValues: ["model": "gpt-5.6", "effort": "xhigh", "speed": "fast"]
        )

        let reopened = ComposerDefaultsStore(store: store)

        #expect(reopened.lastHarnessId(forServer: "local") == "codex")
        #expect(reopened.configSelections(forHarness: "codex", onServer: "local") == [
            "model": "gpt-5.6", "effort": "xhigh", "speed": "fast"
        ])
        #expect(store.loadData(forKey: "composer-defaults-pre-v3-backup") == nil)
    }

    @Test("Clear resets active defaults and removes the migration backup")
    func clears() {
        let legacy = #"{"machines":{"local":{"lastHarnessId":"codex","configSelections":{"codex":{"model":"gpt-5.6"}}}},"workspaces":{}}"#
        let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])
        let defaults = ComposerDefaultsStore(store: store)
        #expect(store.loadData(forKey: "composer-defaults-pre-v3-backup") != nil)

        defaults.clear()

        #expect(defaults.lastHarnessId(forServer: "local") == nil)
        #expect(defaults.configSelections(forHarness: "codex", onServer: "local").isEmpty)
        #expect(store.loadData(forKey: "composer-defaults-pre-v3-backup") == nil)
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

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!contents.contains("composer-defaults.json"))
        #expect(contents.contains { $0.hasPrefix("composer-defaults.json.corrupt-") })
    }

    /// Schema tripwire: changing this string requires a decoder fixture for
    /// this exact V3 shape before the golden value is updated.
    @Test("Persisted wire format is stable — schema changes require a migration")
    func wireFormatIsStable() throws {
        let store = InMemoryStore()
        let defaults = ComposerDefaultsStore(store: store)
        defaults.rememberHarnessSelection(serverId: "local", harnessId: "claude-code")
        defaults.rememberConfigSelections(
            serverId: "local",
            harnessId: "claude-code",
            configValues: ["model": "opus", "effort": "high"]
        )
        let data = try #require(store.loadData(forKey: "composer-defaults"))
        let object = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(String(decoding: canonical, as: UTF8.self) == #"{"machines":{"local":{"configSelections":{"claude-code":{"effort":"high","model":"opus"}},"lastHarnessId":"claude-code"}},"version":3}"#)
    }

    @Test("Never shares composer choices between machines")
    func machineIsolation() {
        let defaults = ComposerDefaultsStore(store: InMemoryStore())
        defaults.rememberHarnessSelection(serverId: "remote-a", harnessId: "codex")
        defaults.rememberConfigSelections(
            serverId: "remote-a", harnessId: "codex", configValues: ["model": "model-a"]
        )
        defaults.rememberHarnessSelection(serverId: "remote-b", harnessId: "claude-code")
        defaults.rememberConfigSelections(
            serverId: "remote-b", harnessId: "claude-code", configValues: ["model": "model-b"]
        )

        #expect(defaults.lastHarnessId(forServer: "remote-a") == "codex")
        #expect(defaults.lastHarnessId(forServer: "remote-b") == "claude-code")
        #expect(defaults.configSelections(forHarness: "codex", onServer: "remote-a") == [
            "model": "model-a"
        ])
        #expect(defaults.configSelections(forHarness: "codex", onServer: "remote-b").isEmpty)
    }
}
