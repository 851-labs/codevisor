import Foundation
import Testing

@testable import CodevisorCore

/// The client half of Phase 18: parsing fleet readiness and flipping the
/// per-machine disable overlay through the config plane.
@MainActor
@Suite("McpFleetStatus")
struct McpFleetStatusTests {
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

  @Test("Readiness entries parse per machine, skipping malformed rows")
  func readinessParses() throws {
    let sync = try makeSync()
    sync.applyRemoteChange(
      namespace: "mcp-readiness",
      entries: [
        ServerSyncEntry(
          key: "studio",
          value: .object([
            "servers": .array([
              .object(["name": .string("GitHub"), "state": .string("ready")]),
              .object([
                "name": .string("Computer Use"),
                "state": .string("blocked"),
                "reason": .string("Needs Screen Recording"),
              ]),
              .object(["state": .string("orphan")]),  // malformed: no name
            ])
          ]),
          timestamp: ServerSyncTimestamp(wallMs: 1, counter: 0, deviceId: "studio")
        ),
        ServerSyncEntry(
          key: "junk",
          value: .string("not an object"),
          timestamp: ServerSyncTimestamp(wallMs: 2, counter: 0, deviceId: "junk")
        ),
      ]
    )
    let readiness = McpFleet.readiness(sync)
    #expect(readiness["studio"]?.count == 2)
    #expect(readiness["studio"]?.first?.name == "GitHub")
    #expect(readiness["studio"]?.first?.state == "ready")
    #expect(readiness["studio"]?.last?.reason == "Needs Screen Recording")
    #expect(readiness["junk"] == nil)
  }

  @Test("The disable overlay round-trips and restores by deletion")
  func disableOverlayRoundTrips() throws {
    let sync = try makeSync()
    #expect(McpFleet.isDisabled(sync, machineId: "studio", name: "GitHub") == false)

    McpFleet.setDisabled(sync, machineId: "studio", name: "GitHub", disabled: true)
    #expect(McpFleet.isDisabled(sync, machineId: "studio", name: "GitHub") == true)
    // The overlay names one machine only.
    #expect(McpFleet.isDisabled(sync, machineId: "laptop", name: "GitHub") == false)
    // The entry is a plain LWW write in the shared key shape.
    let entry = sync.entries(namespace: "mcp-overlays").first
    #expect(entry?.key == "enable|studio|GitHub")

    McpFleet.setDisabled(sync, machineId: "studio", name: "GitHub", disabled: false)
    #expect(McpFleet.isDisabled(sync, machineId: "studio", name: "GitHub") == false)
    #expect(sync.entries(namespace: "mcp-overlays").first?.deleted == true)
  }
}
