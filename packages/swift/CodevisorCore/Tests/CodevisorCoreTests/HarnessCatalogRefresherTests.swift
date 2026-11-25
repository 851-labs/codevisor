import ACPKit
import CodevisorTestSupport
import ConcurrencyExtras
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("HarnessCatalogRefresher", .timeLimit(.minutes(1)))
struct HarnessCatalogRefresherTests {
  private static let machine = CodevisorMachine.local.id

  @Test("Signing in refreshes the machine's models without a composer open")
  func signInRefreshesModels() async {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.capabilitiesHandler = { _ in ServerCapabilities(harnesses: [Self.codex, Self.claude]) }
    let environment = makeEnvironment(fake)
    environment.configCache.store([Self.codex], forServer: Self.machine)

    environment.machines.onHarnessAuthChanged?(Self.machine)

    await awaitObserved { !environment.configCache.options(forHarness: "claude-code", onServer: Self.machine).isEmpty }
    #expect(
      environment.configCache.capabilities(forServer: Self.machine).map(\.harness.id) == ["codex", "claude-code"])
  }

  @Test("A harness whose model check failed is retried within seconds until it reports models")
  func retriesFailedModelCheck() async {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    let checks = LockIsolated(0)
    fake.capabilitiesHandler = { _ in
      let check = checks.withValue { count in
        count += 1
        return count
      }
      return ServerCapabilities(harnesses: [check < 3 ? Self.claudeCheckFailed : Self.claude])
    }
    let cache = ConfigOptionCache(store: InMemoryStore())
    cache.store([Self.codex], forServer: Self.machine)
    let clock = TestClock()
    let refresher = HarnessCatalogRefresher(cache: cache, clock: clock)

    refresher.refetch(forServer: Self.machine, client: fake)
    await clock.waitForSleep(.seconds(2))
    #expect(cache.options(forHarness: "claude-code", onServer: Self.machine).isEmpty)
    #expect(cache.needsCapabilityRevalidation(forServer: Self.machine))

    clock.advance(by: .seconds(2))
    await clock.waitForSleep(.seconds(4))
    clock.advance(by: .seconds(4))

    await awaitObserved { !cache.options(forHarness: "claude-code", onServer: Self.machine).isEmpty }
    #expect(checks.value == 3)
    #expect(!cache.needsCapabilityRevalidation(forServer: Self.machine))
  }

  private func makeEnvironment(_ fake: SyncFakeServerClient) -> AppEnvironment {
    AppEnvironment(
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: AppSettingsModel(store: InMemoryStore()),
      machineStore: InMemoryStore(),
      harnessService: PreviewHarnessService(),
      machineClientFactory: { _ in fake }
    )
  }

  nonisolated private static let codex = capability(id: "codex", name: "Codex", model: "gpt-5")
  nonisolated private static let claude = capability(id: "claude-code", name: "Claude Code", model: "opus")
  nonisolated private static let claudeCheckFailed = ServerHarnessCapability(
    harness: harness(id: "claude-code", name: "Claude Code"), configOptions: [], inspectionFailed: true)

  nonisolated private static func capability(id: String, name: String, model: String) -> ServerHarnessCapability {
    ServerHarnessCapability(
      harness: harness(id: id, name: name),
      configOptions: [
        SessionConfigOption(
          id: "model", name: "Model", category: SessionConfigOption.Category.model, currentValue: model,
          options: [SessionConfigSelectOption(value: model, name: model)])
      ]
    )
  }

  nonisolated private static func harness(id: String, name: String) -> ServerHarness {
    ServerHarness(
      id: id, name: name, symbolName: "sparkle", source: "registry", launchKind: "executable",
      enabled: true, readiness: ServerHarnessReadiness(state: "ready", detail: nil))
  }
}
