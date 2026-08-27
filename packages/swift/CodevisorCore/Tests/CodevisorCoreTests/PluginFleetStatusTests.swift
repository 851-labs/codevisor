import Foundation
import Testing

@testable import CodevisorCore

/// Phase 24's client half for plugins: parsing reported per-machine rows.
@MainActor
@Suite("PluginFleetStatus")
struct PluginFleetStatusTests {
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
            namespace: "plugin-readiness",
            entries: [
                ServerSyncEntry(
                    key: "studio",
                    value: .object([
                        "plugins": .array([
                            .object(["id": .string("scratchpad"), "state": .string("ready")]),
                            .object([
                                "id": .string("ffmpeg-tools"),
                                "state": .string("blocked"),
                                "reason": .string("needs ffmpeg"),
                            ]),
                            .object(["id": .string("dev-linked"), "state": .string("machineOnly")]),
                            .object(["state": .string("orphan")]),  // malformed: no id
                        ])
                    ]),
                    timestamp: ServerSyncTimestamp(wallMs: 1, counter: 0, deviceId: "studio")
                )
            ]
        )
        let readiness = PluginFleet.readiness(sync)
        let rows = readiness["studio"] ?? []
        #expect(rows.map(\.pluginId) == ["scratchpad", "ffmpeg-tools", "dev-linked"])
        #expect(rows[1].reason == "needs ffmpeg")
        #expect(rows[2].state == "machineOnly")
    }
}
