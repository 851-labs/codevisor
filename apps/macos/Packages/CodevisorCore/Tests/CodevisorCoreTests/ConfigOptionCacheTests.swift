import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("ConfigOptionCache")
struct ConfigOptionCacheTests {
    private func option(_ value: String) -> SessionConfigOption {
        SessionConfigOption(id: "model", name: "Model", category: "model", currentValue: value,
                            options: [SessionConfigSelectOption(value: value, name: value.uppercased())])
    }

    @Test("Stores and retrieves options per harness")
    func roundTrip() {
        let cache = ConfigOptionCache(store: InMemoryStore())
        #expect(cache.options(forHarness: "claude-code").isEmpty)
        cache.store([option("opus")], forHarness: "claude-code")
        #expect(cache.options(forHarness: "claude-code").first?.currentValue == "opus")
        #expect(cache.options(forHarness: "codex").isEmpty)
    }

    @Test("Persists across instances (stale-while-revalidate seed)")
    func persists() {
        let store = InMemoryStore()
        ConfigOptionCache(store: store).store([option("gpt-5.5")], forHarness: "codex")
        let reopened = ConfigOptionCache(store: store)
        #expect(reopened.options(forHarness: "codex").first?.currentValue == "gpt-5.5")
    }

    @Test("Persists full server capabilities per machine")
    func serverCapabilitiesPersist() {
        let store = InMemoryStore()
        let capability = ServerHarnessCapability(
            harness: ServerHarness(
                id: "codex",
                name: "Codex",
                symbolName: "chevron.left.forwardslash.chevron.right",
                source: "registry",
                launchKind: "npx",
                enabled: true,
                readiness: ServerHarnessReadiness(state: "ready", detail: nil)
            ),
            modes: SessionModeState(
                currentModeId: "default",
                availableModes: [SessionMode(id: "default", name: "Default")]
            ),
            configOptions: [option("gpt-5.6")]
        )
        ConfigOptionCache(store: store).store([capability], forServer: "local")

        let reopened = ConfigOptionCache(store: store)
        #expect(reopened.capabilities(forServer: "local").first?.harness.id == "codex")
        #expect(reopened.options(forHarness: "codex").first?.currentValue == "gpt-5.6")
    }

    @Test("Corrupted cache decodes as empty")
    func corrupted() {
        let store = InMemoryStore(storage: ["harness-config": Data("nope".utf8)])
        let cache = ConfigOptionCache(store: store)
        #expect(cache.options(forHarness: "x").isEmpty)
    }

    @Test("Speculative warm does not overwrite an existing capability snapshot")
    func speculativeWarmPreservesExistingSnapshot() {
        let cache = ConfigOptionCache(store: InMemoryStore())
        let warm = capability(model: "warm")
        let projectSpecific = capability(model: "project")

        #expect(cache.storeIfEmpty([warm], forServer: "local"))
        cache.store([projectSpecific], forServer: "local")
        #expect(!cache.storeIfEmpty([warm], forServer: "local"))
        #expect(cache.capabilities(forServer: "local").first?.configOptions.first?.currentValue == "project")
    }

    private func capability(model: String) -> ServerHarnessCapability {
        ServerHarnessCapability(
            harness: ServerHarness(
                id: "codex",
                name: "Codex",
                symbolName: "chevron.left.forwardslash.chevron.right",
                source: "registry",
                launchKind: "npx",
                enabled: true,
                readiness: ServerHarnessReadiness(state: "ready", detail: nil)
            ),
            modes: nil,
            configOptions: [option(model)]
        )
    }
}
