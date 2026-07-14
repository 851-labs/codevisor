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

    @Test("Corrupted data decodes as empty")
    func corrupted() {
        let store = InMemoryStore(storage: ["composer-defaults": Data("nope".utf8)])
        let defaults = ComposerDefaultsStore(store: store)
        #expect(defaults.lastHarnessId(forServer: "local") == nil)
        #expect(defaults.runInWorktree(forServer: "local") == false)
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
