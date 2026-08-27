import Foundation
import Observation
import Testing

@testable import CodevisorCore

/// Phase 22: one roster entry per machine, with the persisted
/// direct↔cloud link backing dedup and the relay fallback route.
@MainActor
@Suite("MachineController routes")
struct MachineControllerRouteTests {
    private func makeCloudMachine(
        deviceId: String = "dev-1",
        name: String = "Cloud Mac",
        online: Bool = true
    ) -> CloudMachine {
        CloudMachine(
            deviceId: deviceId,
            name: name,
            os: "macOS",
            publicKey: "pk-\(deviceId)",
            online: online,
            lastSeenAt: "2026-01-01T00:00:00.000Z"
        )
    }
    /// Defaults to a working local server (the mac shape). Tests that model
    /// a client-only platform (iOS) pass `localServer: nil` explicitly —
    /// those platforms list no "Local" machine and auto-adopt real ones.
    private func makeController(
        store: InMemoryStore = InMemoryStore(),
        localServer: (any LocalServerControlling)? = StubLocalServer(),
        clientFactory: MachineController.ClientFactory? = nil
    ) -> (controller: MachineController, projectList: ProjectListModel, provider: FakeCloudProvider) {
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: store,
            projectList: projectList,
            localServer: localServer,
            clientFactory: clientFactory
        )
        let provider = FakeCloudProvider()
        controller.cloudProvider = provider
        return (controller, projectList, provider)
    }

    @Test("A successful direct probe persists the cloud link on the record")
    func probePersistsCloudLink() async throws {
        let store = InMemoryStore()
        // The remote's direct probe answers with a cloud identity.
        let linkedRemote = SyncFakeServerClient(projects: [], sessions: [])
        linkedRemote.configureInfoCloudDeviceId("dev-1")
        let factory: MachineController.ClientFactory = { machine in
            machine.isLocal ? SyncFakeServerClient(projects: [], sessions: []) : linkedRemote
        }
        let (controller, _, provider) = makeController(store: store, clientFactory: factory)
        provider.cloudMachines = [makeCloudMachine()]
        let machineId = try controller.addRemote(host: "10.0.0.9", name: "Studio").id
        // The direct probe rides the registered fake client factory.
        await controller.refreshStatus(for: machineId)
        #expect(controller.statusByMachineId[machineId]?.cloudDeviceId == "dev-1")

        let persisted = try JSONDecoder().decode(
            MachineRegistry.self,
            from: #require(store.loadData(forKey: "machines"))
        )
        #expect(persisted.remoteMachines.first?.cloudDeviceId == "dev-1")
        // The persisted link dedupes the cloud twin with NO live status.
        let (relaunched, _, provider2) = makeController(store: store)
        provider2.cloudMachines = [makeCloudMachine()]
        #expect(!relaunched.allMachines.contains { $0.id == "cloud:dev-1" })
    }

    @Test("A dead direct route fails over to the cloud relay")
    func directDownRidesRelay() async throws {
        let store = InMemoryStore()
        let deadDirect: MachineController.ClientFactory = { machine in
            machine.isLocal
                ? SyncFakeServerClient(projects: [], sessions: [])
                : CodevisorServerClient(config: .unreachable(machineId: machine.id))
        }
        let (controller, _, provider) = makeController(store: store, clientFactory: deadDirect)
        provider.cloudMachines = [makeCloudMachine()]
        provider.requestTransport.responsesByPath["/v1/info"] = """
            {"id":"m1","name":"Studio","kind":"remote","version":"2.0.0",
             "platform":"darwin","bindHost":"127.0.0.1","cloudDeviceId":"dev-1"}
            """
        let machineId = try controller.addRemote(host: "10.0.0.9", name: "Studio").id
        // Seed the persisted link (as a past successful probe would have).
        controller.adoptCloudLinkForTesting(machineId: machineId, deviceId: "dev-1")

        await controller.refreshStatus(for: machineId)
        let status = try #require(controller.statusByMachineId[machineId])
        #expect(status.isReachable)
        #expect(status.route == MachineRoute.relay)
        #expect(status.label.contains("via Codevisor Cloud"))

        // client(for:) now rides the relay: requests hit the fake transport.
        let info = try await controller.client(for: machineId).info()
        #expect(info.name == "Studio")
        #expect(provider.requestTransport.paths.contains("/v1/info"))
    }
}
