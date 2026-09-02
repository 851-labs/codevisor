import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

/// The machine list as replicated config: publishing on add/remove, quiet
/// application of learned entries, and tombstoned removals.
@MainActor
@Suite("FleetRoster")
struct FleetRosterTests {
  private func waitFor(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for condition")
  }

  private func makeWorld() -> (
    MachineController, ConfigSync, FleetRoster, SyncFakeServerClient
  ) {
    let localFake = SyncFakeServerClient(projects: [], sessions: [])
    let remoteFake = SyncFakeServerClient(projects: [], sessions: [])
    remoteFake.configureInfoId("srv-linux")
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel(
        projectRepository: DefaultProjectRepository(store: InMemoryStore()),
        sessionRepository: DefaultSessionRepository(store: InMemoryStore())
      ),
      clientFactory: { machine in machine.id == "local" ? localFake : remoteFake }
    )
    let sync = ConfigSync(machines: controller, store: InMemoryStore())
    let roster = FleetRoster(machines: controller, configSync: sync, store: InMemoryStore())
    controller.onMachineAdded = { roster.publishMachine($0) }
    controller.onMachineRemoved = { roster.publishRemoval(localMachineId: $0) }
    return (controller, sync, roster, remoteFake)
  }

  private func rosterEntry(deleted: Bool = false) -> ServerSyncEntry {
    ServerSyncEntry(
      key: "srv-linux",
      value: deleted
        ? .null
        : .object([
          "name": .string("Linux"),
          "url": .string("http://linux.test:49361"),
          "token": .string("hm_secret"),
        ]),
      deleted: deleted ? true : nil,
      timestamp: ServerSyncTimestamp(
        wallMs: deleted ? 20 : 10,
        counter: 0,
        deviceId: "other-device"
      )
    )
  }

  @Test("Adding a machine publishes a roster entry with route and token")
  func addPublishes() async throws {
    let (controller, sync, _, _) = makeWorld()

    _ = try await controller.addRemoteValidating(
      host: "linux.test",
      name: "Linux",
      token: "hm_secret"
    )

    try await waitFor { sync.value(namespace: "machines", key: "srv-linux") != nil }
    guard case .object(let value)? = sync.value(namespace: "machines", key: "srv-linux") else {
      Issue.record("Missing roster entry")
      return
    }
    #expect(value["name"] == .string("Linux"))
    #expect(value["url"] == .string("http://linux.test:49361"))
    #expect(value["token"] == .string("hm_secret"))
    controller.stopEventSync()
  }

  @Test("Roster entries apply quietly and idempotently")
  func rosterApplies() async throws {
    let (controller, sync, roster, _) = makeWorld()
    let before = controller.selectedMachineId
    sync.applyRemoteChange(namespace: "machines", entries: [rosterEntry()])

    await roster.applyRoster()
    await roster.applyRoster()

    let added = controller.allMachines.filter {
      $0.baseURL.absoluteString == "http://linux.test:49361"
    }
    #expect(added.count == 1)
    #expect(added.first?.name == "Linux")
    #expect(added.first?.token == "hm_secret")
    // The user's selection never moves for a background join.
    #expect(controller.selectedMachineId == before)
    controller.stopEventSync()
  }

  @Test("A roster tombstone removes the machine it named")
  func tombstoneRemoves() async throws {
    let (controller, sync, roster, _) = makeWorld()
    sync.applyRemoteChange(namespace: "machines", entries: [rosterEntry()])
    await roster.applyRoster()
    #expect(
      controller.allMachines.contains {
        $0.baseURL.absoluteString == "http://linux.test:49361"
      })

    sync.applyRemoteChange(namespace: "machines", entries: [rosterEntry(deleted: true)])
    await roster.applyRoster()

    #expect(
      !controller.allMachines.contains {
        $0.baseURL.absoluteString == "http://linux.test:49361"
      })
    controller.stopEventSync()
  }

  @Test("Removing a machine locally tombstones it fleet-wide")
  func removalPublishes() async throws {
    let (controller, sync, _, _) = makeWorld()
    let machine = try await controller.addRemoteValidating(
      host: "linux.test",
      token: "hm_secret"
    )
    try await waitFor { sync.value(namespace: "machines", key: "srv-linux") != nil }

    try controller.removeMachine(machine.id)

    #expect(sync.value(namespace: "machines", key: "srv-linux") == nil)
    #expect(
      sync.entries(namespace: "machines").first { $0.key == "srv-linux" }?.deleted == true)
    controller.stopEventSync()
  }
}
