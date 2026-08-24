import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

/// The client half of the config plane: local replica, HLC stamping, and
/// the gossip that converges every reachable machine.
@MainActor
@Suite("ConfigSync")
struct ConfigSyncTests {
    private func makeRemote(_ id: String) -> CodevisorMachine {
        CodevisorMachine(
            id: id,
            name: id,
            baseURL: URL(string: "http://\(id).test:49361")!,
            kind: "remote"
        )
    }

    private func makeController(
        fakes: [String: SyncFakeServerClient],
        remotes: [CodevisorMachine]
    ) throws -> MachineController {
        let store = InMemoryStore()
        try store.saveData(
            JSONEncoder().encode(
                MachineRegistry(selectedMachineId: "local", remoteMachines: remotes)
            ),
            forKey: "machines"
        )
        return MachineController(
            store: store,
            projectList: ProjectListModel(
                projectRepository: DefaultProjectRepository(store: InMemoryStore()),
                sessionRepository: DefaultSessionRepository(store: InMemoryStore())
            ),
            clientFactory: { machine in
                fakes[machine.id] ?? SyncFakeServerClient(projects: [], sessions: [])
            }
        )
    }

    private func waitForSync(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for sync condition")
    }

    @Test("Writes stamp strictly increasing clocks and persist locally")
    func writesStampAndPersist() throws {
        let controller = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: [])],
            remotes: []
        )
        let store = InMemoryStore()
        let sync = ConfigSync(machines: controller, store: store)

        sync.set(namespace: "settings", key: "updateChannel", value: .string("alpha"))
        sync.set(namespace: "settings", key: "updateChannel", value: .string("stable"))

        let entries = sync.entries(namespace: "settings")
        #expect(entries.count == 1)
        #expect(sync.value(namespace: "settings", key: "updateChannel") == .string("stable"))

        // The replica survives a fresh instance over the same store, and the
        // device id is stable.
        let reloaded = ConfigSync(machines: controller, store: store)
        #expect(reloaded.value(namespace: "settings", key: "updateChannel") == .string("stable"))
        #expect(reloaded.deviceId == sync.deviceId)
    }

    @Test("A write gossips to every reachable machine")
    func writesGossip() async throws {
        let remoteA = makeRemote("remote-a")
        let remoteB = makeRemote("remote-b")
        let fakeA = SyncFakeServerClient(projects: [], sessions: [])
        let fakeB = SyncFakeServerClient(projects: [], sessions: [])
        let controller = try makeController(
            fakes: [
                "local": SyncFakeServerClient(projects: [], sessions: []),
                remoteA.id: fakeA,
                remoteB.id: fakeB,
            ],
            remotes: [remoteA, remoteB]
        )
        await controller.refreshStatus(for: remoteA.id)
        await controller.refreshStatus(for: remoteB.id)
        let sync = ConfigSync(machines: controller, store: InMemoryStore())

        sync.set(namespace: "settings", key: "updateChannel", value: .string("alpha"))

        try await waitForSync {
            fakeA.syncEntries(namespace: "settings").count == 1
                && fakeB.syncEntries(namespace: "settings").count == 1
        }
        #expect(fakeA.syncEntries(namespace: "settings").first?.value == .string("alpha"))
    }

    @Test("Synchronizing adopts newer remote entries and pushes local ones")
    func synchronizeConverges() async throws {
        let remote = makeRemote("remote-a")
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.seedSyncEntries(
            namespace: "settings",
            [
                ServerSyncEntry(
                    key: "updateChannel",
                    value: .string("alpha"),
                    timestamp: ServerSyncTimestamp(
                        wallMs: 10_000_000_000_000,
                        counter: 0,
                        deviceId: "other-device"
                    )
                )
            ]
        )
        let controller = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
            remotes: [remote]
        )
        let sync = ConfigSync(machines: controller, store: InMemoryStore())
        sync.set(namespace: "settings", key: "theme", value: .string("dark"))

        await sync.synchronize(machineId: remote.id)

        // The remote's (far-future) channel wins locally; the local theme
        // landed remotely in the same round trip.
        #expect(sync.value(namespace: "settings", key: "updateChannel") == .string("alpha"))
        #expect(fake.syncEntries(namespace: "settings").contains { $0.key == "theme" })
        #expect(sync.revisionsByNamespace["settings", default: 0] >= 2)
    }

    @Test("Tombstones remove values and win over older writes")
    func tombstonesWin() throws {
        let controller = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: [])],
            remotes: []
        )
        let sync = ConfigSync(machines: controller, store: InMemoryStore())
        sync.set(namespace: "settings", key: "theme", value: .string("dark"))
        sync.remove(namespace: "settings", key: "theme")

        #expect(sync.value(namespace: "settings", key: "theme") == nil)
        #expect(sync.entries(namespace: "settings").first?.deleted == true)

        // A remote write OLDER than the tombstone does not resurrect it.
        let stale = ServerSyncEntry(
            key: "theme",
            value: .string("light"),
            timestamp: ServerSyncTimestamp(wallMs: 1, counter: 0, deviceId: "old-device")
        )
        sync.applyRemoteChange(namespace: "settings", entries: [stale])
        #expect(sync.value(namespace: "settings", key: "theme") == nil)
    }
}
