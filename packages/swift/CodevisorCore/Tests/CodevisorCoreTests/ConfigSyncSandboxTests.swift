import ACPKit
import CodevisorCloud
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("ConfigSync with sandboxes")
struct ConfigSyncSandboxTests {
  private let regular = accountMachine("regular")
  private let sandbox = accountMachine("sandbox")
  private let regularFake = SyncFakeServerClient(projects: [], sessions: [])
  private let sandboxFake = SyncFakeServerClient(projects: [], sessions: [])

  private func makeSync() async -> ConfigSync {
    let fakes = [
      "local": SyncFakeServerClient(projects: [], sessions: []),
      regular.id: regularFake,
      sandbox.id: sandboxFake,
    ]
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      clientFactory: { fakes[$0.id] ?? SyncFakeServerClient(projects: [], sessions: []) }
    )
    let provider = signIn(controller, machines: [regular, sandbox])
    provider.cloudMachines = provider.cloudMachines.map(markingSandboxSandbox)
    await controller.refreshStatus(for: regular.id)
    await controller.refreshStatus(for: sandbox.id)
    return ConfigSync(machines: controller, store: InMemoryStore())
  }

  private func markingSandboxSandbox(_ machine: CloudMachine) -> CloudMachine {
    guard machine.deviceId == "sandbox" else { return machine }
    var marked = machine
    marked.ephemeral = CloudEphemeralOrigin(provider: "e2b", ownerDeviceId: "regular")
    return marked
  }

  private func entry(_ key: String, _ value: String) -> ServerSyncEntry {
    ServerSyncEntry(
      key: key,
      value: .string(value),
      timestamp: ServerSyncTimestamp(wallMs: 10_000_000_000_000, counter: 0, deviceId: "sandbox")
    )
  }

  @Test("A local write gossips to regular machines and never to a sandbox one")
  func writesSkipSandbox() async throws {
    let sync = await makeSync()

    sync.set(namespace: "settings", key: "theme", value: .string("dark"))
    await awaitObserved { regularFake.syncEntries(namespace: "settings").count == 1 }
    await sync.synchronizeAll()

    #expect(sandboxFake.syncEntries(namespace: "settings").isEmpty)
  }

  @Test("Nothing a sandbox holds is adopted, by sync or by its change events")
  func neverAdoptsFromSandbox() async throws {
    sandboxFake.seedSyncEntries(namespace: "settings", [entry("updateChannel", "alpha")])
    let sync = await makeSync()

    await sync.synchronize(machineId: sandbox.id)
    await sync.synchronizeMachine(sandbox.id)
    await sync.synchronizeAll()
    sync.applyRemoteChange(
      namespace: "settings",
      entries: [entry("theme", "neon")],
      fromMachine: sandbox.id
    )

    #expect(sync.value(namespace: "settings", key: "updateChannel") == nil)
    #expect(sync.value(namespace: "settings", key: "theme") == nil)
    #expect(sandboxFake.syncEntries(namespace: "settings").map(\.key) == ["updateChannel"])
  }

  @Test("Change events from a regular machine still apply")
  func regularChangesApply() async throws {
    let sync = await makeSync()

    sync.applyRemoteChange(
      namespace: "settings",
      entries: [entry("theme", "dark")],
      fromMachine: regular.id
    )

    #expect(sync.value(namespace: "settings", key: "theme") == .string("dark"))
  }
}
