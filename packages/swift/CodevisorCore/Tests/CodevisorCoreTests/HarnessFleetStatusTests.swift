import Foundation
import Testing

@testable import CodevisorCore

/// Phase 24's client half: parsing each machine's reported harness states.
@MainActor
@Suite("HarnessFleetStatus")
struct HarnessFleetStatusTests {
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
      namespace: "harness-readiness",
      entries: [
        ServerSyncEntry(
          key: "studio",
          value: .object([
            "harnesses": .array([
              .object(["id": .string("claude-code"), "state": .string("ready")]),
              .object([
                "id": .string("codex"),
                "state": .string("signInRequired"),
              ]),
              .object([
                "id": .string("gemini"),
                "state": .string("notInstalled"),
                "reason": .string("CLI not found on PATH"),
              ]),
              .object(["state": .string("orphan")]),  // malformed: no id
            ])
          ]),
          timestamp: ServerSyncTimestamp(wallMs: 1, counter: 0, deviceId: "studio")
        ),
        ServerSyncEntry(
          key: "junk",
          value: .string("not an object"),
          timestamp: ServerSyncTimestamp(wallMs: 1, counter: 0, deviceId: "junk")
        ),
      ]
    )
    let readiness = HarnessFleet.readiness(sync)
    #expect(readiness.keys.sorted() == ["studio"])
    let rows = readiness["studio"] ?? []
    #expect(rows.map(\.harnessId) == ["claude-code", "codex", "gemini"])
    #expect(rows[1].state == "signInRequired")
    #expect(rows[2].reason == "CLI not found on PATH")
  }
}
