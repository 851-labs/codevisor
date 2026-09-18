import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

/// Seeding the shared harness catalog from a machine's discovery, so the
/// Harnesses settings page has rows after onboarding — and, once, for
/// installs that onboarded before onboarding wrote the catalog.
@MainActor
@Suite("HarnessFleetSeed")
struct HarnessFleetSeedTests {
  @Test("Ready, enabled harnesses become catalog rows; the rest do not")
  func seedsReadyEnabledOnly() throws {
    let sync = try makeSync()

    let added = HarnessFleet.seed(
      from: [
        harness("claude-code", name: "Claude Code", ready: true, desiredEnabled: true),
        harness("codex", name: "Codex", ready: true, desiredEnabled: false),
        harness("gemini", name: "Gemini", ready: false, desiredEnabled: true),
      ],
      in: sync)

    #expect(added == ["claude-code"])
    let settings = HarnessFleet.settings(sync)
    #expect(settings.map(\.id) == ["claude-code"])
    #expect(settings.first?.name == "Claude Code")
    #expect(settings.first?.enabled == true)
    #expect(settings.first?.installed == true)
  }

  @Test("Authored catalog rows and uninstall directives are never overwritten")
  func preservesAuthoredRows() throws {
    let sync = try makeSync()
    HarnessFleet.set(
      .init(id: "claude-code", name: "Claude Code", symbolName: "terminal", enabled: false, installed: true),
      in: sync)
    HarnessFleet.set(
      .init(id: "codex", name: "Codex", symbolName: "terminal", enabled: true, installed: false),
      in: sync)

    let added = HarnessFleet.seed(
      from: [
        harness("claude-code", name: "Claude Code", ready: true, desiredEnabled: true),
        harness("codex", name: "Codex", ready: true, desiredEnabled: true),
      ],
      in: sync)

    #expect(added.isEmpty)
    #expect(HarnessFleet.settings(sync).map(\.enabled) == [false])
    #expect(HarnessFleet.settings(sync, includingUninstalled: true).map(\.installed) == [true, false])
  }

  @Test("A leftover discovery row is not a preference and gets replaced")
  func replacesLegacyDiscoveryRow() throws {
    let sync = try makeSync()
    // What servers published before the catalog became client-authored.
    sync.set(
      namespace: "harnesses", key: "claude-code",
      value: .object(["enabled": .bool(true), "installed": .bool(false)]))
    #expect(HarnessFleet.settings(sync, includingUninstalled: true).isEmpty)

    let added = HarnessFleet.seed(
      from: [harness("claude-code", name: "Claude Code", ready: true, desiredEnabled: true)],
      in: sync)

    #expect(added == ["claude-code"])
    #expect(HarnessFleet.settings(sync).map(\.id) == ["claude-code"])
  }

  @Test("Seeding is idempotent")
  func idempotent() throws {
    let sync = try makeSync()
    let catalog = [harness("claude-code", name: "Claude Code", ready: true, desiredEnabled: true)]

    #expect(HarnessFleet.seed(from: catalog, in: sync) == ["claude-code"])
    let revision = sync.revisionsByNamespace["harnesses"]
    #expect(HarnessFleet.seed(from: catalog, in: sync).isEmpty)
    #expect(sync.revisionsByNamespace["harnesses"] == revision)
  }

  // MARK: - One-time catch-up for already-onboarded installs

  @Test("An onboarded install with an unauthored catalog seeds once from the local machine")
  func environmentSeedsOnce() async {
    let machineStore = InMemoryStore()
    let service = SeedHarnessService(
      result: .success([harness("claude-code", name: "Claude Code", ready: true, desiredEnabled: true)]))
    let environment = makeEnvironment(machineStore: machineStore, service: service, onboarded: true)

    await environment.seedHarnessCatalogIfNeeded(from: "local")
    #expect(HarnessFleet.settings(environment.configSync).map(\.id) == ["claude-code"])

    // The marker persists with the machine store: a later launch with more
    // harnesses ready never seeds again.
    let later = makeEnvironment(
      machineStore: machineStore,
      service: SeedHarnessService(
        result: .success([
          harness("claude-code", name: "Claude Code", ready: true, desiredEnabled: true),
          harness("codex", name: "Codex", ready: true, desiredEnabled: true),
        ])),
      onboarded: true)
    await later.seedHarnessCatalogIfNeeded(from: "local")
    #expect(HarnessFleet.settings(later.configSync).map(\.id) == ["claude-code"])
  }

  @Test("An authored catalog is left alone and still counts as done")
  func environmentHonorsAuthoredCatalog() async {
    let machineStore = InMemoryStore()
    let service = SeedHarnessService(
      result: .success([harness("claude-code", name: "Claude Code", ready: true, desiredEnabled: true)]))
    let environment = makeEnvironment(machineStore: machineStore, service: service, onboarded: true)
    HarnessFleet.set(
      .init(id: "codex", name: "Codex", symbolName: "terminal", enabled: true, installed: true),
      in: environment.configSync)

    await environment.seedHarnessCatalogIfNeeded(from: "local")

    #expect(HarnessFleet.settings(environment.configSync).map(\.id) == ["codex"])
    #expect(machineStore.loadData(forKey: AppEnvironment.harnessCatalogSeedKey) != nil)
  }

  @Test("Onboarding owns the seed while it is still running")
  func environmentWaitsForOnboarding() async {
    let machineStore = InMemoryStore()
    let service = SeedHarnessService(
      result: .success([harness("claude-code", name: "Claude Code", ready: true, desiredEnabled: true)]))
    let environment = makeEnvironment(machineStore: machineStore, service: service, onboarded: false)

    await environment.seedHarnessCatalogIfNeeded(from: "local")

    #expect(HarnessFleet.settings(environment.configSync).isEmpty)
    #expect(machineStore.loadData(forKey: AppEnvironment.harnessCatalogSeedKey) == nil)
  }

  @Test("An unreachable local server leaves the catch-up pending for the next connect")
  func environmentRetriesAfterFailure() async {
    struct Unreachable: Error {}
    let machineStore = InMemoryStore()
    let failing = makeEnvironment(
      machineStore: machineStore, service: SeedHarnessService(result: .failure(Unreachable())),
      onboarded: true)

    await failing.seedHarnessCatalogIfNeeded(from: "local")
    #expect(HarnessFleet.settings(failing.configSync).isEmpty)
    #expect(machineStore.loadData(forKey: AppEnvironment.harnessCatalogSeedKey) == nil)

    let reachable = makeEnvironment(
      machineStore: machineStore,
      service: SeedHarnessService(
        result: .success([harness("claude-code", name: "Claude Code", ready: true, desiredEnabled: true)])),
      onboarded: true)
    await reachable.seedHarnessCatalogIfNeeded(from: "local")
    #expect(HarnessFleet.settings(reachable.configSync).map(\.id) == ["claude-code"])
    #expect(machineStore.loadData(forKey: AppEnvironment.harnessCatalogSeedKey) != nil)
  }

  // MARK: - Fixtures

  private func harness(_ id: String, name: String, ready: Bool, desiredEnabled: Bool) -> ServerHarness {
    ServerHarness(
      id: id, name: name, symbolName: "terminal", source: "registry", launchKind: "executable",
      enabled: ready && desiredEnabled,
      readiness: ServerHarnessReadiness(state: ready ? "ready" : "unavailable"),
      desiredEnabled: desiredEnabled)
  }

  private func makeSync() throws -> ConfigSync {
    let store = InMemoryStore()
    try store.saveData(
      JSONEncoder().encode(MachineRegistry(selectedMachineId: "local", remoteMachines: [])),
      forKey: "machines"
    )
    let controller = MachineController(
      store: store,
      projectList: ProjectListModel(
        projectRepository: DefaultProjectRepository(store: InMemoryStore()),
        sessionRepository: DefaultSessionRepository(store: InMemoryStore())
      ),
      clientFactory: { _ in SyncFakeServerClient(projects: [], sessions: []) }
    )
    return ConfigSync(machines: controller, store: store)
  }

  private func makeEnvironment(
    machineStore: InMemoryStore, service: SeedHarnessService, onboarded: Bool
  ) -> AppEnvironment {
    let settings = AppSettingsModel(store: InMemoryStore())
    if onboarded { settings.completeOnboarding(importExternalSessions: false) }
    return AppEnvironment(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: settings,
      machineStore: machineStore,
      harnessService: service,
      machineClientFactory: { _ in SyncFakeServerClient(projects: [], sessions: []) }
    )
  }
}

private struct SeedHarnessService: HarnessServicing {
  let result: Result<[ServerHarness], any Error>

  func readyHarnesses() async -> [ServerHarness] {
    ((try? result.get()) ?? []).filter { $0.enabled && $0.isReady }
  }
  func allHarnesses() async throws -> [ServerHarness] { try result.get() }
  func listSessions(forHarnessId harnessId: String) async throws -> [SessionInfo] { [] }
}
