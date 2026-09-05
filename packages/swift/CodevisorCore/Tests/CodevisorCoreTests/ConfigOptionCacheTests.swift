import Foundation
import Testing
import CodevisorTestSupport
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("ConfigOptionCache")
struct ConfigOptionCacheTests {
  private func option(_ value: String) -> SessionConfigOption {
    SessionConfigOption(
      id: "model", name: "Model", category: "model", currentValue: value,
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

  @Test("A single-harness refresh preserves the rest of the server catalog")
  func singleHarnessMerge() {
    let cache = ConfigOptionCache(store: InMemoryStore())
    let codex = capability(model: "old")
    var claude = capability(model: "sonnet")
    claude.harness.id = "claude-code"
    cache.store([codex, claude], forServer: "local")

    cache.store(capability(model: "new"), forServer: "local")

    #expect(cache.capabilities(forServer: "local").map(\.harness.id) == ["codex", "claude-code"])
    #expect(cache.options(forHarness: "codex", onServer: "local").first?.currentValue == "new")
    #expect(cache.options(forHarness: "claude-code", onServer: "local").first?.currentValue == "sonnet")
  }

  @Test("Invalidating one server retains stale picker data while requiring revalidation")
  func invalidatesPickerDataPerServer() {
    let store = InMemoryStore()
    let cache = ConfigOptionCache(store: store)
    cache.store([capability(model: "local")], forServer: "local")
    cache.store([capability(model: "remote")], forServer: "remote")

    cache.invalidateCapabilities(forServer: "local")

    #expect(cache.capabilities(forServer: "local").first?.configOptions.first?.currentValue == "local")
    #expect(cache.options(forHarness: "codex", onServer: "local").first?.currentValue == "local")
    #expect(cache.needsCapabilityRevalidation(forServer: "local", cwd: "/project"))
    #expect(cache.capabilities(forServer: "remote").first?.configOptions.first?.currentValue == "remote")
    #expect(cache.options(forHarness: "codex", onServer: "remote").first?.currentValue == "remote")

    let reopened = ConfigOptionCache(store: store)
    #expect(reopened.capabilities(forServer: "local").first?.configOptions.first?.currentValue == "local")
    #expect(reopened.options(forHarness: "codex", onServer: "local").first?.currentValue == "local")
  }

  @Test("A response started before invalidation cannot restore stale capabilities")
  func rejectsInvalidatedResponse() {
    let cache = ConfigOptionCache(store: InMemoryStore())
    let revision = cache.capabilityRevision(forServer: "local")

    cache.invalidateCapabilities(forServer: "local")

    #expect(!cache.store([capability(model: "stale")], forServer: "local", ifRevision: revision))
    #expect(cache.capabilities(forServer: "local").isEmpty)
  }

  @Test("Concurrent drafts share one live capability refresh")
  func coalescesRefreshes() async throws {
    let cache = ConfigOptionCache(store: InMemoryStore())
    let counter = CapabilityRefreshCounter()
    let response = [capability(model: "fresh")]

    let entered = TestSignal()
    let release = TestSignal()
    let first = Task {
      try await cache.revalidateCapabilities(
        forServer: "local", cwd: "/project",
        fetch: {
          await counter.increment()
          entered.signal()
          await release.wait()
          return response
        })
    }
    await entered.wait()
    let joining = TestSignal()
    let second = Task { @MainActor in
      joining.signal()
      return try await cache.revalidateCapabilities(
        forServer: "local", cwd: "/project",
        fetch: {
          await counter.increment()
          return response
        })
    }
    await joining.wait()
    release.signal()
    _ = try await (first.value, second.value)
    #expect(await counter.value == 1)
    #expect(!cache.needsCapabilityRevalidation(forServer: "local", cwd: "/project"))
  }

  @Test("A failed empty inspection keeps the last usable picker options")
  func emptyInspectionPreservesStaleOptions() async throws {
    let cache = ConfigOptionCache(store: InMemoryStore())
    let stale = capability(model: "fable")
    cache.store([stale], forServer: "local")
    var empty = stale
    empty.configOptions = []
    let emptyResponse = [empty]

    let refreshed = try await cache.revalidateCapabilities(
      forServer: "local",
      cwd: "/project",
      fetch: { emptyResponse }
    )

    #expect(refreshed?.first?.configOptions.first?.currentValue == "fable")
    #expect(cache.options(forHarness: "codex", onServer: "local").first?.currentValue == "fable")
  }

  @Test("A refresh in another project makes the server-wide snapshot stale here")
  func projectSpecificFreshnessTracksStoredSnapshot() async throws {
    let cache = ConfigOptionCache(store: InMemoryStore())
    let response = [capability(model: "fresh")]

    _ = try await cache.revalidateCapabilities(
      forServer: "local",
      cwd: "/project-a",
      fetch: { response }
    )
    #expect(!cache.needsCapabilityRevalidation(forServer: "local", cwd: "/project-a"))

    _ = try await cache.revalidateCapabilities(
      forServer: "local",
      cwd: "/project-b",
      fetch: { response }
    )
    #expect(cache.needsCapabilityRevalidation(forServer: "local", cwd: "/project-a"))
    #expect(!cache.needsCapabilityRevalidation(forServer: "local", cwd: "/project-b"))
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

  private func harness(_ id: String, enabled: Bool) -> ServerHarness {
    ServerHarness(
      id: id,
      name: id.capitalized,
      symbolName: "sparkle",
      source: "registry",
      launchKind: "npx",
      enabled: enabled,
      readiness: ServerHarnessReadiness(state: "ready", detail: nil)
    )
  }

  @Test("Revalidation splits usable capabilities from sign-in-pending, persisted per machine")
  func signInPendingSplit() async throws {
    let store = InMemoryStore()
    let cache = ConfigOptionCache(store: store)
    let usable = ServerHarnessCapability(
      harness: harness("codex", enabled: true), configOptions: [option("gpt")])
    let pending = ServerHarnessCapability(
      harness: harness("claude-code", enabled: false), configOptions: [])
    let merged = try await cache.revalidateCapabilities(
      forServer: "remote-a", cwd: "/tmp", force: true, fetch: { [usable, pending] })
    #expect(merged?.map(\.harness.id) == ["codex"])
    #expect(cache.capabilities(forServer: "remote-a").map(\.harness.id) == ["codex"])
    #expect(cache.signInRequired(forServer: "remote-a").map(\.id) == ["claude-code"])
    // Machine-scoped and persisted, like everything else here.
    #expect(cache.signInRequired(forServer: "remote-b").isEmpty)
    let reopened = ConfigOptionCache(store: store)
    #expect(reopened.signInRequired(forServer: "remote-a").map(\.id) == ["claude-code"])

    // A machine that signs everything in clears its pending list.
    let signedIn = ServerHarnessCapability(
      harness: harness("claude-code", enabled: true), configOptions: [option("opus")])
    _ = try await cache.revalidateCapabilities(
      forServer: "remote-a", cwd: "/tmp", force: true, fetch: { [usable, signedIn] })
    #expect(cache.signInRequired(forServer: "remote-a").isEmpty)
    #expect(cache.capabilities(forServer: "remote-a").count == 2)
  }
}

private actor CapabilityRefreshCounter {
  private(set) var value = 0

  func increment() {
    value += 1
  }
}
