import Foundation
import Testing
import ACPKit
@testable import HerdManCore

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

    @Test("Corrupted cache decodes as empty")
    func corrupted() {
        let store = InMemoryStore(storage: ["harness-config": Data("nope".utf8)])
        let cache = ConfigOptionCache(store: store)
        #expect(cache.options(forHarness: "x").isEmpty)
    }
}
