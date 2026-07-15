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

    @Test("Remote host input normalizes to an HTTP server URL")
    func normalizedRemoteURL() throws {
        #expect(try MachineController.normalizedRemoteURL(from: "mac-mini.tailnet.ts.net").absoluteString == "http://mac-mini.tailnet.ts.net:49361")
        #expect(try MachineController.normalizedRemoteURL(from: "https://10.0.0.5:9999/path?x=1").absoluteString == "https://10.0.0.5:9999")
        #expect(throws: MachineControllerError.invalidHost(" ")) {
            _ = try MachineController.normalizedRemoteURL(from: " ")
        }
    }

    @Test("Adding and selecting remotes persists the registry")
    func addSelectAndPersistRemote() throws {
        let store = InMemoryStore()
        let first = makeController(store: store)
        let remote = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net")

        #expect(remote.id == "remote-mac-mini-tailnet-ts-net-49361")
        #expect(remote.name == "mac-mini.tailnet.ts.net")
        #expect(first.controller.selectedMachine == remote)
        #expect(first.projectList.selectedServerId == remote.id)

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

    @Test("Machine icon customizations persist for local and remote machines")
    func machineAppearancesPersist() throws {
        let store = InMemoryStore()
        let first = makeController(store: store)
        let remote = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net")
        let localAppearance = MachineAppearance(symbolName: "laptopcomputer")
        let remoteAppearance = MachineAppearance(symbolName: "server.rack")

        first.controller.setAppearance(localAppearance, for: CodevisorMachine.local.id)
        first.controller.setAppearance(remoteAppearance, for: remote.id)

        #expect(first.controller.machine(for: "local")?.resolvedAppearance == localAppearance)
        #expect(first.controller.machine(for: remote.id)?.resolvedAppearance == remoteAppearance)

        let second = makeController(store: store)
        #expect(second.controller.machine(for: "local")?.resolvedAppearance == localAppearance)
        #expect(second.controller.machine(for: remote.id)?.resolvedAppearance == remoteAppearance)
    }

    @Test("Machines without saved appearance metadata use stable defaults")
    func legacyAppearanceDefaults() throws {
        let legacyRegistry = """
        {
          "selectedMachineId": "remote-studio-49361",
          "remoteMachines": [{
            "id": "remote-studio-49361",
            "name": "Studio",
            "baseURL": "http://studio:49361",
            "kind": "remote"
          }]
        }
        """
        let store = InMemoryStore()
        try store.saveData(Data(legacyRegistry.utf8), forKey: "machines")

        let controller = makeController(store: store).controller

        #expect(controller.machine(for: "local")?.resolvedAppearance == .localDefault)
        #expect(controller.machine(for: "remote-studio-49361")?.resolvedAppearance == .remoteDefault)
    }

    @Test("Legacy saved colors are ignored while their icons remain")
    func legacyMachineColorsAreIgnored() throws {
        let legacyAppearance = """
        {
          "symbolName": "server.rack",
          "colorHex": "#ff3b30"
        }
        """

        let appearance = try JSONDecoder().decode(MachineAppearance.self, from: Data(legacyAppearance.utf8))

        #expect(appearance == MachineAppearance(symbolName: "server.rack"))
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
            clientFactory: { _ in RescanCountingClient() }
        )
        let added = try await accepting.addRemoteValidating(host: "10.0.0.5", token: "hm_ok")
        #expect(accepting.machines.contains(added))
        #expect(accepting.selectedMachine == added)
    }

    @Test("Server events keep projects and sessions in sync across clients")
    func eventSyncRefreshesAndRemoves() async throws {
        let projectId = UUID()
        let sessionId = UUID()
        let fake = SyncFakeServerClient(
            projects: [
                ServerProject(
                    id: projectId.uuidString,
                    name: "Shared",
                    isArchived: false,
                    symbolName: "folder",
                    origin: .codevisor,
                    createdAt: "2026-06-30T00:00:00.000Z",
                    locations: [
                        ServerProjectLocation(
                            id: UUID().uuidString,
                            projectId: projectId.uuidString,
                            serverId: "local",
                            folderPath: "/tmp/shared",
                            createdAt: "2026-06-30T00:00:00.000Z",
                            isGitRepository: nil
                        )
                    ]
                )
            ],
            sessions: []
        )
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            clientFactory: { _ in fake }
        )

        // Another client creates a session on the same server.
        controller.startEventSync()
        fake.setSessions([
            ServerSession(
                id: sessionId.uuidString,
                projectId: projectId.uuidString,
                serverId: "local",
                harnessId: "claude-code",
                agentSessionId: nil,
                title: "From another client",
                origin: .codevisor,
                isArchived: false,
                createdAt: "2026-06-30T00:00:01.000Z",
                updatedAt: nil,
                usage: nil
            )
        ])
        fake.emit(kind: "session.created", subjectId: sessionId.uuidString)
        try await waitForSync { projectList.sessions.contains { $0.id == sessionId } }
        #expect(projectList.projects.contains { $0.id == projectId })

        // Another client deletes the session, then the project.
        fake.setSessions([])
        fake.emit(kind: "session.deleted", subjectId: sessionId.uuidString)
        try await waitForSync { !projectList.sessions.contains { $0.id == sessionId } }

        fake.emit(kind: "project.deleted", subjectId: projectId.uuidString)
        try await waitForSync { !projectList.projects.contains { $0.id == projectId } }

        controller.stopEventSync()
    }

    @Test("Client-triggered server update waits for the restart and reconnects")
    func remoteServerUpdate() async throws {
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            clientFactory: { _ in fake },
            updatePollInterval: .milliseconds(2),
            updatePollAttempts: 50
        )

        await controller.refreshStatus(for: "local")
        #expect(controller.selectedServerUpdate?.updateAvailable == true)
        #expect(controller.selectedServerUpdate?.latestVersion == "0.2.0")

        await controller.updateSelectedServer()

        #expect(fake.appliedUpdates == 1)
        #expect(controller.serverUpdatePhase == .idle)
        // After the restart the banner state clears and the status shows the
        // new version.
        #expect(controller.selectedServerUpdate?.updateAvailable == false)
        #expect(controller.statusByMachineId["local"]?.label.contains("0.2.0") == true)
        controller.stopEventSync()

        // Triggering again is a no-op that just refreshes state.
        await controller.updateSelectedServer()
        #expect(controller.serverUpdatePhase == .idle)
        #expect(fake.appliedUpdates == 2)
    }

    @Test("A busy server declines the update with a clear message")
    func remoteServerUpdateRefusedWhileBusy() async throws {
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
        fake.configureBusy(true)
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            clientFactory: { _ in fake },
            updatePollInterval: .milliseconds(2),
            updatePollAttempts: 50
        )

        await controller.updateSelectedServer()

        // The server declined (chats running), so the phase reports a failure
        // and the update was not applied/restarted.
        if case let .failed(message) = controller.serverUpdatePhase {
            #expect(message.contains("chats running"))
        } else {
            Issue.record("Expected a failed phase, got \(controller.serverUpdatePhase)")
        }
        controller.stopEventSync()
    }

    private func waitForSync(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for sync condition")
    }

    @Test("prepareSelectedMachine rescans harnesses on an already-running local server")
    func rescanOnAlreadyRunningServer() async throws {
        let client = RescanCountingClient()
        // A healthy durable server: ensureRunning resolves .alreadyRunning
        // without launching, which must trigger exactly one PATH rescan (the
        // durable server's PATH is frozen at its original launch).
        let localServer = LocalCodevisorServer(
            client: client,
            entrypoint: URL(fileURLWithPath: "/tmp/main.js"),
            launcher: { _ in Process() }
        )
        let (controller, _, _) = makeController(client: client, localServer: localServer)

        await controller.prepareSelectedMachine()
        try await waitForSync { client.rescans == 1 }
        controller.stopEventSync()

        #expect(localServer.state == .alreadyRunning)
        #expect(client.rescans == 1)
    }

    @Test("prepareSelectedMachine skips the rescan when it launches the server fresh")
    func noRescanOnFreshLaunch() async throws {
        // First health probe fails (no durable server); the post-launch poll
        // succeeds. A fresh launch already resolved PATH — no rescan needed.
        let client = RescanCountingClient(failFirstHealth: true)
        let localServer = LocalCodevisorServer(
            client: client,
            entrypoint: URL(fileURLWithPath: "/tmp/main.js"),
            launcher: { _ in Process() }
        )
        let (controller, _, _) = makeController(client: client, localServer: localServer)

        await controller.prepareSelectedMachine()
        try await Task.sleep(nanoseconds: 30_000_000)
        controller.stopEventSync()

        #expect(localServer.state == .started)
        #expect(client.rescans == 0)
    }

    private func makeController(store: InMemoryStore = InMemoryStore()) -> (
        controller: MachineController,
        projectList: ProjectListModel,
        store: InMemoryStore
    ) {
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(store: store, projectList: projectList)
        return (controller, projectList, store)
    }

    private func makeController(
        client: any CodevisorServerClienting,
        localServer: LocalCodevisorServer
    ) -> (
        controller: MachineController,
        projectList: ProjectListModel,
        store: InMemoryStore
    ) {
        let store = InMemoryStore()
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: store,
            projectList: projectList,
            localServer: localServer,
            clientFactory: { _ in client }
        )
        return (controller, projectList, store)
    }
}

/// Counts rescan calls; healthy by default so `ensureRunning` sees a durable
/// server, or unhealthy on the first probe to force a fresh launch.
private final class RescanCountingClient: CodevisorServerClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _rescans = 0
    private var _failNextHealth: Bool
    /// When set, `info()` throws it — used to exercise add-time validation.
    let infoError: (any Error)?

    init(failFirstHealth: Bool = false, infoError: (any Error)? = nil) {
        _failNextHealth = failFirstHealth
        self.infoError = infoError
    }

    var rescans: Int { lock.withLock { _rescans } }

    struct HealthError: Error {}

    func health() async throws -> ServerHealth {
        let failNow = lock.withLock {
            let fail = _failNextHealth
            _failNextHealth = false
            return fail
        }
        if failNow { throw HealthError() }
        return ServerHealth(ok: true, version: "0.1.0", database: "ready")
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
    func updateInfo() async throws -> ServerUpdateInfo {
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

/// A fake server whose event stream and list endpoints are test-driven.
private final class SyncFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _projects: [ServerProject]
    private var _sessions: [ServerSession]
    private var continuations: [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation] = []
    private var emittedEvents: [ServerEventEnvelope] = []
    private var nextEventId = 1

    init(projects: [ServerProject], sessions: [ServerSession]) {
        _projects = projects
        _sessions = sessions
    }

    func setSessions(_ sessions: [ServerSession]) {
        lock.withLock { _sessions = sessions }
    }

    func emit(kind: String, subjectId: String) {
        let (event, targets): (ServerEventEnvelope, [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation]) = lock.withLock {
            let event = ServerEventEnvelope(
                id: nextEventId,
                serverId: "local",
                kind: kind,
                subjectId: subjectId,
                createdAt: "2026-06-30T00:00:02.000Z",
                payload: .null
            )
            nextEventId += 1
            emittedEvents.append(event)
            return (event, continuations)
        }
        for continuation in targets {
            continuation.yield(event)
        }
    }

    /// Mirrors the real server: replays the event log from `since`, then
    /// streams new events.
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in
            let backlog: [ServerEventEnvelope] = lock.withLock {
                continuations.append(continuation)
                return emittedEvents.filter { $0.id > since }
            }
            for event in backlog {
                continuation.yield(event)
            }
        }
    }

    func listProjects() async throws -> [ServerProject] { lock.withLock { _projects } }
    func listSessions() async throws -> [ServerSession] { lock.withLock { _sessions } }

    // MARK: - Simulated server versioning / self-update

    private var currentVersion = "0.1.0"
    private var latestVersion = "0.1.0"
    private var downtimeRemaining = 0
    private var _appliedUpdates = 0
    private var _busy = false

    struct ServerDownError: Error {}

    var appliedUpdates: Int { lock.withLock { _appliedUpdates } }

    /// Makes the fake report an available update to `latest`.
    func configureUpdate(current: String, latest: String) {
        lock.withLock {
            currentVersion = current
            latestVersion = latest
        }
    }

    /// Makes `applyServerUpdate()` decline as busy (chats still running).
    func configureBusy(_ value: Bool) {
        lock.withLock { _busy = value }
    }

    func health() async throws -> ServerHealth {
        ServerHealth(ok: true, version: lock.withLock { currentVersion }, database: "ready")
    }
    func info() async throws -> ServerInfo {
        let version: String = try lock.withLock {
            if downtimeRemaining > 0 {
                downtimeRemaining -= 1
                throw ServerDownError()
            }
            return currentVersion
        }
        return ServerInfo(id: "local", name: "Local", kind: "local", version: version, platform: "darwin", bindHost: "127.0.0.1")
    }
    func updateInfo() async throws -> ServerUpdateInfo {
        lock.withLock {
            ServerUpdateInfo(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                updateAvailable: currentVersion != latestVersion,
                channel: "stable",
                checkedAt: nil,
                migrationState: "idle"
            )
        }
    }
    func applyServerUpdate() async throws -> ServerUpdateApplied {
        lock.withLock {
            _appliedUpdates += 1
            if _busy {
                return ServerUpdateApplied(accepted: false, targetVersion: currentVersion, reason: "busy")
            }
            guard currentVersion != latestVersion else {
                return ServerUpdateApplied(accepted: false, targetVersion: currentVersion)
            }
            // The server restarts: unreachable for a few probes, then back on
            // the new version.
            downtimeRemaining = 3
            currentVersion = latestVersion
            return ServerUpdateApplied(accepted: true, targetVersion: latestVersion)
        }
    }
    func issuePairingToken() async throws -> ServerPairingToken {
        ServerPairingToken(token: "hm_test", createdAt: "2026-06-30T00:00:00.000Z")
    }
    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
    func listHarnesses() async throws -> [ServerHarness] { [] }
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
    func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func deleteProject(id: UUID) async throws {}
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
}
