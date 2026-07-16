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
        #expect(cache.options(forHarness: "claude-code", onServer: "local").isEmpty)
        cache.store([option("opus")], forHarness: "claude-code", onServer: "local")
        #expect(cache.options(forHarness: "claude-code", onServer: "local").first?.currentValue == "opus")
        #expect(cache.options(forHarness: "codex", onServer: "local").isEmpty)
    }

    @Test("Persists across instances (stale-while-revalidate seed)")
    func persists() {
        let store = InMemoryStore()
        ConfigOptionCache(store: store).store([option("gpt-5.5")], forHarness: "codex", onServer: "local")
        let reopened = ConfigOptionCache(store: store)
        #expect(reopened.options(forHarness: "codex", onServer: "local").first?.currentValue == "gpt-5.5")
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
        #expect(reopened.options(forHarness: "codex", onServer: "local").first?.currentValue == "gpt-5.6")
        #expect(reopened.options(forHarness: "codex", onServer: "remote").isEmpty)
    }

    @Test("Corrupted cache decodes as empty")
    func corrupted() {
        let store = InMemoryStore(storage: ["harness-config": Data("nope".utf8)])
        let cache = ConfigOptionCache(store: store)
        #expect(cache.options(forHarness: "x", onServer: "local").isEmpty)
    }

    @Test("Never shares a harness's options between machines")
    func machineIsolation() {
        let store = InMemoryStore()
        let cache = ConfigOptionCache(store: store)
        cache.store([option("local-model")], forHarness: "codex", onServer: "local")
        cache.store([option("remote-model")], forHarness: "codex", onServer: "remote-a")

        #expect(cache.options(forHarness: "codex", onServer: "local").first?.currentValue == "local-model")
        #expect(cache.options(forHarness: "codex", onServer: "remote-a").first?.currentValue == "remote-model")
        #expect(cache.options(forHarness: "codex", onServer: "remote-b").isEmpty)

        let reopened = ConfigOptionCache(store: store)
        #expect(reopened.options(forHarness: "codex", onServer: "remote-a").first?.currentValue == "remote-model")
        #expect(reopened.options(forHarness: "codex", onServer: "remote-b").isEmpty)
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

    @Test("Catalog seed renders immediately and is replaced by the capability warm")
    func provisionalCatalogSeed() {
        let cache = ConfigOptionCache(store: InMemoryStore())
        let catalogHarness = capability(model: "unused").harness

        cache.seedHarnesses([catalogHarness], forServer: "local")

        #expect(cache.capabilities(forServer: "local").map(\.harness.id) == ["codex"])
        #expect(cache.capabilities(forServer: "local").first?.configOptions.isEmpty == true)
        #expect(cache.needsCapabilityWarm(forServer: "local"))

        #expect(cache.storeIfEmpty([capability(model: "warm")], forServer: "local"))
        #expect(!cache.needsCapabilityWarm(forServer: "local"))
        #expect(cache.capabilities(forServer: "local").first?.configOptions.first?.currentValue == "warm")
    }

    @Test("Catalog seed cannot replace a newer project-specific snapshot")
    func provisionalCatalogSeedPreservesNewerSnapshot() {
        let cache = ConfigOptionCache(store: InMemoryStore())
        let projectSpecific = capability(model: "project")
        cache.store([projectSpecific], forServer: "local")

        cache.seedHarnesses([projectSpecific.harness], forServer: "local")

        #expect(!cache.needsCapabilityWarm(forServer: "local"))
        #expect(cache.capabilities(forServer: "local").first?.configOptions.first?.currentValue == "project")
    }

    @Test("Invalidating one server drops its catalog but preserves config choices")
    func invalidatesCatalogPerServer() {
        let store = InMemoryStore()
        let cache = ConfigOptionCache(store: store)
        cache.store([capability(model: "local")], forServer: "local")
        cache.store([capability(model: "remote")], forServer: "remote")

        cache.invalidateCapabilities(forServer: "local")

        #expect(cache.capabilities(forServer: "local").isEmpty)
        #expect(cache.options(forHarness: "codex", onServer: "local").first?.currentValue == "local")
        #expect(cache.capabilities(forServer: "remote").first?.configOptions.first?.currentValue == "remote")

        let reopened = ConfigOptionCache(store: store)
        #expect(reopened.capabilities(forServer: "local").isEmpty)
        #expect(reopened.options(forHarness: "codex", onServer: "local").first?.currentValue == "local")
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
