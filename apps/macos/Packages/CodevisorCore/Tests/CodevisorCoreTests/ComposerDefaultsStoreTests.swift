import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("ComposerDefaultsStore")
struct ComposerDefaultsStoreTests {
    @Test("Starts empty")
    func startsEmpty() {
        let defaults = ComposerDefaultsStore(store: InMemoryStore())
        #expect(defaults.lastHarnessId == nil)
        #expect(defaults.runInWorktree == false)
        #expect(defaults.configSelections(forHarness: "claude-code").isEmpty)
    }

    @Test("Remembers the choices a session was created with")
    func remembersCreationChoices() {
        let defaults = ComposerDefaultsStore(store: InMemoryStore())
        defaults.rememberSessionCreation(
            harnessId: "claude-code",
            configValues: ["model": "opus", "thought_level": "high"],
            runInWorktree: true
        )
        #expect(defaults.lastHarnessId == "claude-code")
        #expect(defaults.runInWorktree == true)
        #expect(defaults.configSelections(forHarness: "claude-code") == [
            "model": "opus", "thought_level": "high"
        ])
    }

    @Test("Keeps per-harness selections independent")
    func perHarnessSelections() {
        let defaults = ComposerDefaultsStore(store: InMemoryStore())
        defaults.rememberSessionCreation(
            harnessId: "claude-code", configValues: ["model": "opus"], runInWorktree: false
        )
        defaults.rememberSessionCreation(
            harnessId: "codex", configValues: ["model": "gpt-5.5"], runInWorktree: false
        )
        #expect(defaults.lastHarnessId == "codex")
        #expect(defaults.configSelections(forHarness: "claude-code") == ["model": "opus"])
        #expect(defaults.configSelections(forHarness: "codex") == ["model": "gpt-5.5"])
    }

    @Test("A nil or empty harness id keeps the previous harness defaults")
    func nilHarnessKeepsPrevious() {
        let defaults = ComposerDefaultsStore(store: InMemoryStore())
        defaults.rememberSessionCreation(
            harnessId: "claude-code", configValues: ["model": "opus"], runInWorktree: true
        )
        defaults.rememberSessionCreation(harnessId: nil, configValues: [:], runInWorktree: false)
        #expect(defaults.lastHarnessId == "claude-code")
        #expect(defaults.configSelections(forHarness: "claude-code") == ["model": "opus"])
        // The worktree choice still updates — it isn't harness-scoped.
        #expect(defaults.runInWorktree == false)
    }

    @Test("Persists across instances")
    func persists() {
        let store = InMemoryStore()
        ComposerDefaultsStore(store: store).rememberSessionCreation(
            harnessId: "codex", configValues: ["model": "gpt-5.5"], runInWorktree: true
        )
        let reopened = ComposerDefaultsStore(store: store)
        #expect(reopened.lastHarnessId == "codex")
        #expect(reopened.runInWorktree == true)
        #expect(reopened.configSelections(forHarness: "codex") == ["model": "gpt-5.5"])
    }

    @Test("Clear resets everything")
    func clears() {
        let store = InMemoryStore()
        let defaults = ComposerDefaultsStore(store: store)
        defaults.rememberSessionCreation(
            harnessId: "codex", configValues: ["model": "gpt-5.5"], runInWorktree: true
        )
        defaults.clear()
        #expect(defaults.lastHarnessId == nil)
        #expect(defaults.runInWorktree == false)
        #expect(defaults.configSelections(forHarness: "codex").isEmpty)
        let reopened = ComposerDefaultsStore(store: store)
        #expect(reopened.lastHarnessId == nil)
    }

    @Test("Corrupted data decodes as empty")
    func corrupted() {
        let store = InMemoryStore(storage: ["composer-defaults": Data("nope".utf8)])
        let defaults = ComposerDefaultsStore(store: store)
        #expect(defaults.lastHarnessId == nil)
        #expect(defaults.runInWorktree == false)
    }
}
