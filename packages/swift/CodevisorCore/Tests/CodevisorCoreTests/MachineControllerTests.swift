import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("MachineController")
struct MachineControllerTests {
    @Test("Registry starts with local machine selected")
    func localDefault() {
        let (controller, projectList, _) = makeController()

        #expect(controller.machines == [.local])
        #expect(controller.selectedMachine == .local)
        #expect(projectList.selectedServerId == "local")
    }

    @Test("Adding and selecting remotes persists the registry")
    func addSelectAndPersistRemote() throws {
        let store = InMemoryStore()
        let first = makeController(store: store)
        let remote = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net")

        #expect(remote.id == "remote-mac-mini-tailnet-ts-net-49361")
        #expect(remote.name == "mac-mini.tailnet.ts.net")
        #expect(first.controller.selectedMachine == remote)
        // Composer defaults never re-route the project model.
        #expect(first.projectList.selectedServerId == "local")

        first.controller.selectMachine("local")
        #expect(first.projectList.selectedServerId == "local")

        let second = makeController(store: store)
        #expect(second.controller.machines.contains(remote))
        #expect(second.controller.selectedMachine == .local)
        #expect(second.projectList.selectedServerId == "local")

        let duplicate = try second.controller.addRemote(host: "http://mac-mini.tailnet.ts.net:49361")
        #expect(duplicate == remote)
        #expect(second.controller.machines.filter { $0 == remote }.count == 1)
    }

    @Test("Remote tokens persist and flow into the server config")
    func remoteTokens() throws {
        let store = InMemoryStore()
        let first = makeController(store: store)

        let remote = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net", token: " hm_secret ")
        #expect(remote.token == "hm_secret")
        #expect(remote.serverConfig.bearerToken == "hm_secret")

        // Re-adding with a new token rotates it; without one keeps it.
        _ = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net", token: "hm_rotated")
        #expect(first.controller.machine(for: remote.id)?.token == "hm_rotated")
        _ = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net")
        #expect(first.controller.machine(for: remote.id)?.token == "hm_rotated")

        // The token survives a reload from the persisted registry.
        let second = makeController(store: store)
        #expect(second.controller.machine(for: remote.id)?.token == "hm_rotated")

        // The local machine never carries a token.
        #expect(CodevisorMachine.local.token == nil)
        #expect(CodevisorMachine.local.serverConfig.bearerToken == nil)
    }

    @Test("Live credential storage keeps tokens out of the machine registry")
    func remoteTokensUseCredentialStore() throws {
        let store = InMemoryStore()
        let credentials = InMemoryMachineCredentialStore()
        let first = MachineController(
            store: store,
            projectList: ProjectListModel(
                projectRepository: DefaultProjectRepository(store: InMemoryStore()),
                sessionRepository: DefaultSessionRepository(store: InMemoryStore())
            ),
            credentialStore: credentials
        )

        let remote = try first.addRemote(
            host: "mac-mini.tailnet.ts.net",
            token: "device-secret"
        )
        #expect(try credentials.token(forMachineID: remote.id) == "device-secret")

        let persisted = try JSONDecoder().decode(
            MachineRegistry.self,
            from: #require(store.loadData(forKey: "machines"))
        )
        #expect(persisted.remoteMachines.first?.token == nil)

        let second = MachineController(
            store: store,
            projectList: ProjectListModel(
                projectRepository: DefaultProjectRepository(store: InMemoryStore()),
                sessionRepository: DefaultSessionRepository(store: InMemoryStore())
            ),
            credentialStore: credentials
        )
        #expect(second.machine(for: remote.id)?.token == "device-secret")

        try second.removeMachine(remote.id)
        #expect(try credentials.token(forMachineID: remote.id) == nil)
    }

    @Test("Remotes can be named on add and renamed later, persisted")
    func namedAndRenamedRemote() throws {
        let store = InMemoryStore()
        let first = makeController(store: store)

        let remote = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net", name: "  Mac mini  ")
        #expect(remote.name == "Mac mini")

        // Re-adding the same host with a name updates it; without one keeps it.
        let renamedViaAdd = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net", name: "Studio")
        #expect(renamedViaAdd.id == remote.id)
        #expect(first.controller.machine(for: remote.id)?.name == "Studio")
        _ = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net")
        #expect(first.controller.machine(for: remote.id)?.name == "Studio")

        try first.controller.renameMachine(remote.id, to: "Build box")
        #expect(first.controller.machine(for: remote.id)?.name == "Build box")
        // Blank names are ignored.
        try first.controller.renameMachine(remote.id, to: "   ")
        #expect(first.controller.machine(for: remote.id)?.name == "Build box")

        #expect(throws: MachineControllerError.cannotRenameLocal) {
            try first.controller.renameMachine("local", to: "My Mac")
        }

        let second = makeController(store: store)
        #expect(second.controller.machine(for: remote.id)?.name == "Build box")
    }

    @Test("Legacy machine icon metadata is ignored and stripped on the next save")
    func legacyAppearanceMetadataIsRemoved() throws {
        let legacyRegistry = """
            {
              "selectedMachineId": "remote-studio-49361",
              "localAppearance": {"symbolName": "laptopcomputer"},
              "cloudAppearances": {"cloud:dev-1": {"symbolName": "server.rack"}},
              "remoteMachines": [{
                "id": "remote-studio-49361",
                "name": "Studio",
                "baseURL": "http://studio:49361",
                "kind": "remote",
                "appearance": {"symbolName": "externaldrive"}
              }]
            }
            """
        let store = InMemoryStore()
        try store.saveData(Data(legacyRegistry.utf8), forKey: "machines")

        let controller = makeController(store: store).controller
        try controller.renameMachine("remote-studio-49361", to: "Build box")

        let persistedData = try #require(store.loadData(forKey: "machines"))
        let persisted = try #require(
            JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        #expect(persisted["localAppearance"] == nil)
        #expect(persisted["cloudAppearances"] == nil)
        let remotes = try #require(persisted["remoteMachines"] as? [[String: Any]])
        #expect(remotes.first?["appearance"] == nil)
    }

    @Test("Removing the selected remote falls back to local")
    func removeSelectedRemote() throws {
        let (controller, projectList, _) = makeController()
        let remote = try controller.addRemote(host: "10.0.0.5")

        try controller.removeMachine(remote.id)

        #expect(controller.selectedMachine == .local)
        #expect(controller.machines == [.local])
        #expect(projectList.selectedServerId == "local")
        #expect(throws: MachineControllerError.cannotRemoveLocal) {
            try controller.removeMachine("local")
        }
    }

    @Test("Validated add rejects a bad token and adds a reachable machine")
    func validatedAdd() async throws {
        let store = InMemoryStore()
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        // A client whose probe rejects the token: the machine must not be added.
        let rejecting = MachineController(
            store: store,
            projectList: projectList,
            localServer: StubLocalServer(),
            clientFactory: { _ in
                RescanCountingClient(infoError: CodevisorServerClientError.httpStatus(401, "{}"))
            }
        )
        await #expect(throws: (any Error).self) {
            try await rejecting.addRemoteValidating(host: "10.0.0.5", token: "hm_wrong")
        }
        #expect(rejecting.machines == [.local])

        // A client that answers: the machine is added and selected.
        let accepting = MachineController(
            store: InMemoryStore(),
            projectList: ProjectListModel(
                projectRepository: DefaultProjectRepository(store: InMemoryStore()),
                sessionRepository: DefaultSessionRepository(store: InMemoryStore())
            ),
            localServer: StubLocalServer(),
            clientFactory: { _ in RescanCountingClient() }
        )
        let added = try await accepting.addRemoteValidating(host: "10.0.0.5", token: "hm_ok")
        #expect(accepting.machines.contains(added))
        #expect(accepting.selectedMachine == added)
    }
}

/// Counts rescan calls; healthy by default so `ensureRunning` sees a durable
/// server, or unhealthy on the first probe to force a fresh launch.
private final class RescanCountingClient: CodevisorServerClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _rescans = 0
    private var _failNextHealth: Bool
    private var _bootId: String?
    /// When set, `info()` throws it — used to exercise add-time validation.
    let infoError: (any Error)?

    init(failFirstHealth: Bool = false, infoError: (any Error)? = nil) {
        _failNextHealth = failFirstHealth
        self.infoError = infoError
    }

    var rescans: Int { lock.withLock { _rescans } }

    struct HealthError: Error {}

    func acceptBoot(_ bootId: String) {
        lock.withLock { _bootId = bootId }
    }

    func health() async throws -> ServerHealth {
        let (failNow, bootId) = lock.withLock {
            let fail = _failNextHealth
            _failNextHealth = false
            return (fail, _bootId)
        }
        if failNow { throw HealthError() }
        return ServerHealth(
            ok: true,
            version: "0.1.0",
            database: "ready",
            bootId: bootId
        )
    }

    func info() async throws -> ServerInfo {
        if let infoError { throw infoError }
        return ServerInfo(
            id: "local", name: "Local", kind: "local", version: "0.1.0",
            platform: "darwin", bindHost: "127.0.0.1"
        )
    }

    func rescanHarnesses() async throws -> [ServerHarness] {
        lock.withLock { _rescans += 1 }
        return []
    }

    func listHarnesses() async throws -> [ServerHarness] { [] }
    func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
        ServerUpdateInfo(
            currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false,
            channel: "stable", checkedAt: nil, migrationState: "idle"
        )
    }
    func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
    func listProjects() async throws -> [ServerProject] { [] }
    func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func deleteProject(id: UUID) async throws {}
    func listSessions() async throws -> [ServerSession] { [] }
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail { fatalError("unused") }
    func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func deleteSession(id: UUID) async throws {}
    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
    }
    func cancelSession(id: UUID) async throws {}
    func setSessionMode(id: UUID, modeId: String) async throws {}
    func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
    func requestShutdown() async throws {}
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}
