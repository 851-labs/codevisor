import Foundation
import Observation
import Testing
@testable import CodevisorCore

/// A canned-response request transport standing in for the cloud relay:
/// records every request and serves JSON by path.
private final class FakeRelayRequestTransport: ServerRequestTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requestedPaths: [String] = []
    var responsesByPath: [String: String] = [:]

    var paths: [String] {
        lock.withLock { requestedPaths }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        lock.withLock { requestedPaths.append(path) }
        guard let body = responsesByPath[path] else {
            throw URLError(.fileDoesNotExist)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }
}

private final class UnusedWebSocketTransport: ServerWebSocketTransport, @unchecked Sendable {
    func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
        UnusedWebSocketConnection()
    }
}

/// Never exercised: the fake relay config's request transport answers
/// everything, so no socket is ever opened.
private final class UnusedWebSocketConnection: ServerWebSocketConnecting, @unchecked Sendable {
    var closeCode: URLSessionWebSocketTask.CloseCode { .invalid }

    func send(_ message: ServerWebSocketMessage) async throws {}
    func receive() async throws -> ServerWebSocketMessage {
        throw URLError(.cancelled)
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
}

@MainActor
private final class FakeCloudProvider: CloudMachineProviding {
    var isCloudSignedIn = true
    var cloudMachines: [CloudMachine] = []
    /// Simulates a listening loopback bridge for a machine, like
    /// CloudAccountController publishes once its bridge is up.
    var loopbackURLsByDeviceId: [String: URL] = [:]
    let requestTransport = FakeRelayRequestTransport()
    private(set) var configRequests: [String] = []

    func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig? {
        configRequests.append(machine.deviceId)
        return CodevisorServerConfig(
            baseURL: loopbackBaseURL(for: machine) ?? CodevisorMachine.cloudPlaceholderBaseURL,
            bearerToken: nil,
            requestTransport: requestTransport,
            webSocketTransport: UnusedWebSocketTransport()
        )
    }

    func loopbackBaseURL(for machine: CloudMachine) -> URL? {
        loopbackURLsByDeviceId[machine.deviceId]
    }
}

@MainActor
@Suite("MachineController cloud machines")
struct MachineControllerCloudTests {
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

    private func makeController(
        store: InMemoryStore = InMemoryStore(),
        localServer: (any LocalServerControlling)? = nil,
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

    @Test("allMachines appends synthesized entries for cloud-only machines")
    func allMachinesSynthesis() throws {
        let (controller, _, provider) = makeController()
        provider.cloudMachines = [makeCloudMachine()]

        let all = controller.allMachines
        #expect(all.map(\.id) == ["local", "cloud:dev-1"])
        let cloud = try #require(all.last)
        #expect(cloud.kind == "cloud")
        #expect(cloud.isCloud)
        #expect(cloud.name == "Cloud Mac")
        #expect(cloud.baseURL == CodevisorMachine.cloudPlaceholderBaseURL)
        #expect(cloud.resolvedAppearance == .cloudDefault)
        #expect(controller.machine(for: "cloud:dev-1") == cloud)
    }

    @Test("Cloud entries exist only while signed in")
    func signedOutHidesCloudMachines() {
        let (controller, _, provider) = makeController()
        provider.cloudMachines = [makeCloudMachine()]
        #expect(controller.allMachines.count == 2)

        provider.isCloudSignedIn = false
        #expect(controller.allMachines.map(\.id) == ["local"])
        #expect(controller.machine(for: "cloud:dev-1") == nil)
    }

    @Test("Deduplicates against configured machines by cloud device id, then name")
    func dedup() async throws {
        let deviceId = "dev-configured"
        // A real client over a canned transport, so the configured remote's
        // status probe advertises its cloud device id like a live server.
        let remoteTransport = FakeRelayRequestTransport()
        remoteTransport.responsesByPath["/v1/info"] = """
            {"id":"studio","name":"Studio","kind":"remote","version":"1.0.0",
             "platform":"darwin","bindHost":"0.0.0.0","cloudDeviceId":"\(deviceId)"}
            """
        let (controller, _, provider) = makeController(clientFactory: { machine in
            CodevisorServerClient(
                config: CodevisorServerConfig(
                    baseURL: machine.baseURL,
                    requestTransport: remoteTransport,
                    webSocketTransport: UnusedWebSocketTransport()
                ))
        })
        let remote = try controller.addRemote(host: "studio.tailnet.ts.net")

        provider.cloudMachines = [
            // Same identity as the configured remote (device id match after
            // its status probe answers).
            makeCloudMachine(deviceId: deviceId, name: "Studio (Cloud)"),
            // Name collision with a configured machine.
            makeCloudMachine(deviceId: "dev-name-clash", name: remote.name),
            // Genuinely cloud-only.
            makeCloudMachine(deviceId: "dev-only", name: "Only In Cloud"),
        ]

        // Before the status probe answers, the device-id duplicate is still
        // listed (name fallback doesn't match it).
        #expect(controller.cloudOnlyMachines.map(\.deviceId) == [deviceId, "dev-only"])

        await controller.refreshStatus(for: remote.id)
        #expect(controller.statusByMachineId[remote.id]?.cloudDeviceId == deviceId)
        #expect(controller.cloudOnlyMachines.map(\.deviceId) == ["dev-only"])
        #expect(controller.allMachines.map(\.id) == ["local", remote.id, "cloud:dev-only"])
    }

    /// A controller with one configured remote whose status probe advertises
    /// `deviceId`, plus a cloud twin of that remote on the provider — the
    /// setup for every stale-status deduplication regression below.
    private func makeDedupedRemote(
        deviceId: String
    ) async throws -> (controller: MachineController, provider: FakeCloudProvider, remote: CodevisorMachine) {
        let remoteTransport = FakeRelayRequestTransport()
        remoteTransport.responsesByPath["/v1/info"] = """
            {"id":"studio","name":"Studio","kind":"remote","version":"1.0.0",
             "platform":"darwin","bindHost":"0.0.0.0","cloudDeviceId":"\(deviceId)"}
            """
        let (controller, _, provider) = makeController(clientFactory: { machine in
            CodevisorServerClient(
                config: CodevisorServerConfig(
                    baseURL: machine.baseURL,
                    requestTransport: remoteTransport,
                    webSocketTransport: UnusedWebSocketTransport()
                ))
        })
        let remote = try controller.addRemote(host: "studio.tailnet.ts.net")
        await controller.refreshStatus(for: remote.id)
        provider.cloudMachines = [makeCloudMachine(deviceId: deviceId, name: "Studio (Cloud)")]
        #expect(controller.cloudOnlyMachines.isEmpty)
        return (controller, provider, remote)
    }

    @Test("Removing a machine frees its cloud twin for the unified list")
    func removedMachineStatusDoesNotDeduplicate() async throws {
        let deviceId = "dev-removed"
        let (controller, _, remote) = try await makeDedupedRemote(deviceId: deviceId)

        try controller.removeMachine(remote.id)

        #expect(controller.statusByMachineId[remote.id] == nil)
        #expect(controller.cloudOnlyMachines.map(\.deviceId) == [deviceId])
        #expect(controller.allMachines.map(\.id) == ["local", "cloud:\(deviceId)"])
    }

    @Test("The delete-all-data reset frees cloud twins of removed machines")
    func resetFreesCloudTwins() async throws {
        // The exact post-reset regression: "reset app data" runs in-process
        // (removeAllRemoteMachines), so without pruning, the removed dev
        // remote's stale status kept hiding its cloud entry after the user
        // re-onboarded and signed back in.
        let deviceId = "dev-reset"
        let (controller, _, _) = try await makeDedupedRemote(deviceId: deviceId)

        controller.removeAllRemoteMachines()

        #expect(controller.cloudOnlyMachines.map(\.deviceId) == [deviceId])
        #expect(controller.allMachines.map(\.id) == ["local", "cloud:\(deviceId)"])
    }

    @Test("A status probe landing after removal still doesn't hide the twin")
    func lateProbeAfterRemovalDoesNotDeduplicate() async throws {
        // An in-flight refreshStatus can re-create the removed machine's
        // status entry after removal pruned it. Deduplication must only count
        // statuses of currently configured machines, so even that stale entry
        // cannot hide the cloud twin.
        let deviceId = "dev-late-probe"
        let (controller, _, remote) = try await makeDedupedRemote(deviceId: deviceId)

        try controller.removeMachine(remote.id)
        await controller.refreshStatus(for: remote.id)

        #expect(controller.statusByMachineId[remote.id]?.cloudDeviceId == deviceId)
        #expect(controller.cloudOnlyMachines.map(\.deviceId) == [deviceId])
    }

    @Test("Selecting a cloud machine persists and yields a relay-backed client")
    func cloudSelection() async throws {
        let store = InMemoryStore()
        let (controller, projectList, provider) = makeController(store: store)
        provider.cloudMachines = [makeCloudMachine()]
        provider.requestTransport.responsesByPath["/v1/info"] = """
            {"id":"m1","name":"Cloud Mac","kind":"remote","version":"2.0.0",
             "platform":"darwin","bindHost":"127.0.0.1","cloudDeviceId":"dev-1"}
            """

        controller.selectMachine("cloud:dev-1")
        #expect(controller.selectedMachineId == "cloud:dev-1")
        #expect(controller.selectedMachine.isCloud)
        #expect(projectList.selectedServerId == "cloud:dev-1")
        #expect(provider.configRequests.contains("dev-1"))

        // The client is a real CodevisorServerClient tunneling through the
        // provider's relay transports.
        let info = try await controller.client(for: "cloud:dev-1").info()
        #expect(info.name == "Cloud Mac")
        #expect(provider.requestTransport.paths.contains("/v1/info"))

        // refreshStatus flows through the same relay client.
        await controller.refreshStatus(for: "cloud:dev-1")
        #expect(controller.statusByMachineId["cloud:dev-1"]?.isReachable == true)
        #expect(controller.statusByMachineId["cloud:dev-1"]?.cloudDeviceId == "dev-1")

        // The selection persists (the id is stable across launches).
        let persisted = try JSONDecoder().decode(
            MachineRegistry.self,
            from: #require(store.loadData(forKey: "machines"))
        )
        #expect(persisted.selectedMachineId == "cloud:dev-1")
    }

    @Test("serverConfig(for:) is relay-backed for cloud ids, plain otherwise")
    func serverConfigRouting() {
        let (controller, _, provider) = makeController()
        provider.cloudMachines = [makeCloudMachine()]

        let cloudConfig = controller.serverConfig(for: "cloud:dev-1")
        #expect(cloudConfig.requestTransport != nil)
        #expect(cloudConfig.webSocketTransport != nil)
        #expect(cloudConfig.baseURL == CodevisorMachine.cloudPlaceholderBaseURL)

        let localConfig = controller.serverConfig(for: "local")
        #expect(localConfig.requestTransport == nil)
        #expect(localConfig.baseURL == CodevisorMachine.local.baseURL)
    }

    @Test("A listening loopback bridge replaces the placeholder baseURL")
    func loopbackBaseURLSynthesis() throws {
        let (controller, _, provider) = makeController()
        provider.cloudMachines = [makeCloudMachine()]

        // Before the bridge is up: placeholder everywhere.
        #expect(
            controller.machine(for: "cloud:dev-1")?.baseURL
                == CodevisorMachine.cloudPlaceholderBaseURL
        )

        // Once the bridge listens, baseURL consumers (the external terminal
        // proxy reads machine.baseURL / serverConfig.baseURL) get the real
        // loopback address.
        let loopback = URL(string: "http://127.0.0.1:54321")!
        provider.loopbackURLsByDeviceId["dev-1"] = loopback
        #expect(controller.machine(for: "cloud:dev-1")?.baseURL == loopback)
        #expect(controller.serverConfig(for: "cloud:dev-1").baseURL == loopback)
        // The relay transports stay attached — the loopback URL is for
        // external processes, in-app clients keep tunneling in-process.
        #expect(controller.serverConfig(for: "cloud:dev-1").requestTransport != nil)
    }

    @Test("Setting a cloud machine's appearance reflects in allMachines and persists")
    func cloudAppearance() throws {
        let store = InMemoryStore()
        let (controller, _, provider) = makeController(store: store)
        provider.cloudMachines = [makeCloudMachine()]
        #expect(controller.machine(for: "cloud:dev-1")?.resolvedAppearance == .cloudDefault)

        controller.setAppearance(MachineAppearance(symbolName: "server.rack"), for: "cloud:dev-1")
        #expect(
            controller.machine(for: "cloud:dev-1")?.resolvedAppearance.symbolName == "server.rack"
        )
        // Other machines keep their own appearance.
        #expect(controller.machine(for: "local")?.resolvedAppearance == .localDefault)

        // A simulated relaunch over the same persisted registry keeps the
        // icon — the `cloud:<deviceId>` key is stable across launches.
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let second = MachineController(store: store, projectList: projectList)
        let secondProvider = FakeCloudProvider()
        secondProvider.cloudMachines = [makeCloudMachine()]
        second.cloudProvider = secondProvider
        #expect(
            second.machine(for: "cloud:dev-1")?.resolvedAppearance.symbolName == "server.rack"
        )
    }

    @Test("An invalid cloud appearance falls back to the cloud default")
    func cloudAppearanceInvalidFallsBack() {
        let (controller, _, provider) = makeController()
        provider.cloudMachines = [makeCloudMachine()]

        controller.setAppearance(MachineAppearance(symbolName: "   "), for: "cloud:dev-1")
        #expect(controller.machine(for: "cloud:dev-1")?.resolvedAppearance == .cloudDefault)
    }

    @Test("The delete-all-data reset drops saved cloud appearances")
    func resetDropsCloudAppearances() throws {
        let store = InMemoryStore()
        let (controller, _, provider) = makeController(store: store)
        provider.cloudMachines = [makeCloudMachine()]
        controller.setAppearance(MachineAppearance(symbolName: "server.rack"), for: "cloud:dev-1")
        #expect(!controller.registry.cloudAppearances.isEmpty)

        controller.removeAllRemoteMachines()

        #expect(controller.registry.cloudAppearances.isEmpty)
        #expect(controller.machine(for: "cloud:dev-1")?.resolvedAppearance == .cloudDefault)
        let persisted = try JSONDecoder().decode(
            MachineRegistry.self,
            from: #require(store.loadData(forKey: "machines"))
        )
        #expect(persisted.cloudAppearances.isEmpty)
    }

    @Test("Registries persisted before cloudAppearances decode with an empty map")
    func registryDecodeCompatibility() throws {
        let legacy = """
            {"selectedMachineId":"local","remoteMachines":[]}
            """
        let registry = try JSONDecoder().decode(MachineRegistry.self, from: Data(legacy.utf8))
        #expect(registry.cloudAppearances.isEmpty)
        #expect(registry.selectedMachineId == "local")
    }

    @Test("Sign-out with a cloud machine selected falls back to local")
    func signOutFallsBackToLocal() {
        let (controller, projectList, provider) = makeController()
        provider.cloudMachines = [makeCloudMachine()]
        controller.selectMachine("cloud:dev-1")
        #expect(controller.selectedMachineId == "cloud:dev-1")

        provider.isCloudSignedIn = false
        controller.handleCloudAccountSignedOut()
        #expect(controller.selectedMachineId == "local")
        #expect(controller.selectedMachine == .local)
        #expect(projectList.selectedServerId == "local")
    }

    @Test("A cloud machine arriving with no explicit selection is auto-selected")
    func autoSelectsCloudMachineWhenNoExplicitChoice() async throws {
        let store = InMemoryStore()
        let (controller, projectList, provider) = makeController(store: store)
        provider.requestTransport.responsesByPath["/v1/info"] = """
            {"id":"m1","name":"Dev Remote","kind":"remote","version":"2.0.0",
             "platform":"darwin","bindHost":"127.0.0.1","cloudDeviceId":"dev-1"}
            """
        // Fresh registry: local placeholder selected, no explicit choice.
        #expect(controller.selectedMachineId == "local")
        #expect(controller.registry.hasExplicitMachineSelection == false)

        provider.cloudMachines = [makeCloudMachine()]
        controller.reconcileCloudSelection()

        #expect(controller.selectedMachine.isCloud)
        #expect(controller.selectedMachineId == "cloud:dev-1")
        #expect(projectList.selectedServerId == "cloud:dev-1")
        // Auto-selection must NOT masquerade as an explicit choice.
        #expect(controller.registry.hasExplicitMachineSelection == false)
        // The prepareSelectedMachine path connects through the relay client.
        await controller.prepareSelectedMachine()
        #expect(provider.configRequests.contains("dev-1"))
        #expect(provider.requestTransport.paths.contains("/v1/info"))

        // The auto-selection persists so a relaunch resolves the same machine.
        let persisted = try JSONDecoder().decode(
            MachineRegistry.self,
            from: #require(store.loadData(forKey: "machines"))
        )
        #expect(persisted.selectedMachineId == "cloud:dev-1")
        #expect(persisted.hasExplicitMachineSelection == false)
    }

    @Test("An explicit local choice is never overridden by an arriving cloud machine")
    func explicitLocalSelectionIsNotStolen() {
        let (controller, projectList, provider) = makeController()
        // The user explicitly taps Local.
        controller.selectMachine("local")
        #expect(controller.registry.hasExplicitMachineSelection)

        provider.cloudMachines = [makeCloudMachine()]
        controller.reconcileCloudSelection()

        #expect(controller.selectedMachineId == "local")
        #expect(projectList.selectedServerId == "local")
    }

    @Test("A working local server remains the default when cloud machines arrive")
    func localServerRemainsDefault() {
        let (controller, projectList, provider) = makeController(
            localServer: StubLocalServer()
        )
        #expect(controller.registry.hasExplicitMachineSelection == false)

        provider.cloudMachines = [makeCloudMachine()]
        controller.reconcileCloudSelection()

        #expect(controller.selectedMachineId == "local")
        #expect(projectList.selectedServerId == "local")
        #expect(controller.registry.hasExplicitMachineSelection == false)
    }

    @Test("Auto-selection prefers an online machine over list order")
    func autoSelectPrefersOnlineMachine() {
        let (controller, _, provider) = makeController()
        // Offline machine first in list order, online machine second.
        provider.cloudMachines = [
            makeCloudMachine(deviceId: "dev-offline", name: "Offline Mac", online: false),
            makeCloudMachine(deviceId: "dev-online", name: "Online Mac", online: true),
        ]
        controller.reconcileCloudSelection()

        // Online preference beats list order.
        #expect(controller.selectedMachineId == "cloud:dev-online")
    }

    @Test("Auto-selection falls back to list order when no machine is online")
    func autoSelectFallsBackToListOrderWhenAllOffline() {
        let (controller, _, provider) = makeController()
        provider.cloudMachines = [
            makeCloudMachine(deviceId: "dev-a", name: "A Mac", online: false),
            makeCloudMachine(deviceId: "dev-b", name: "B Mac", online: false),
        ]
        controller.reconcileCloudSelection()

        // No online candidate: the first in list order wins.
        #expect(controller.selectedMachineId == "cloud:dev-a")
    }

    @Test("With only the local machine present, auto-selection stays on local")
    func autoSelectStaysLocalWithNoOtherMachines() {
        let (controller, projectList, _) = makeController()
        // No cloud machines, no remotes: nothing to prefer over local.
        controller.reconcileCloudSelection()

        #expect(controller.selectedMachineId == "local")
        #expect(projectList.selectedServerId == "local")
        #expect(controller.registry.hasExplicitMachineSelection == false)
    }

    @Test("Registries persisted before hasExplicitMachineSelection decode to false")
    func registryDecodesExplicitFlagCompat() throws {
        let legacy = """
            {"selectedMachineId":"local","remoteMachines":[]}
            """
        let registry = try JSONDecoder().decode(MachineRegistry.self, from: Data(legacy.utf8))
        #expect(registry.hasExplicitMachineSelection == false)
    }

    @Test("A persisted cloud selection resolves to local until the account arrives")
    func persistedCloudSelectionFallsBackWhileSignedOut() {
        let store = InMemoryStore()
        let first = makeController(store: store)
        first.provider.cloudMachines = [makeCloudMachine()]
        first.controller.selectMachine("cloud:dev-1")

        // Relaunch without a provider: selection stays persisted, but the
        // resolved machine is local.
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let second = MachineController(store: store, projectList: projectList)
        #expect(second.selectedMachineId == "cloud:dev-1")
        #expect(second.selectedMachine == .local)

        // Once the account's machines arrive, reconciliation rewires the
        // selection to the now-available cloud machine.
        let provider = FakeCloudProvider()
        provider.cloudMachines = [makeCloudMachine()]
        second.cloudProvider = provider
        second.reconcileCloudSelection()
        #expect(second.selectedMachine.isCloud)
        #expect(projectList.selectedServerId == "cloud:dev-1")
    }
}

@MainActor
@Observable
private final class StubLocalServer: LocalServerControlling {
    var state: LocalCodevisorServerState = .idle
    var dataUpgradeProgress: LocalDataUpgradeProgress?
    var onUpdateRequested: (@MainActor () -> Void)?

    func configureManagedService(_ service: LocalCodevisorManagedService) {}
    func ensureRunning() async -> LocalCodevisorServerState { state }
    func prepareForAppUpdate() async -> Bool { true }
    func shutdown() async -> Bool { true }
}
