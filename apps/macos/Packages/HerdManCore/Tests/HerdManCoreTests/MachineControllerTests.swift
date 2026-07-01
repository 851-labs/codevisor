import Foundation
import Testing
import ACPKit
@testable import HerdManCore

@MainActor
@Suite("MachineController")
struct MachineControllerTests {
    @Test("Registry starts with local machine selected")
    func localDefault() {
        let (controller, workspaceList, _) = makeController()

        #expect(controller.machines == [.local])
        #expect(controller.selectedMachine == .local)
        #expect(workspaceList.selectedServerId == "local")
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
        #expect(first.workspaceList.selectedServerId == remote.id)

        first.controller.selectMachine("local")
        #expect(first.workspaceList.selectedServerId == "local")

        let second = makeController(store: store)
        #expect(second.controller.machines.contains(remote))
        #expect(second.controller.selectedMachine == .local)
        #expect(second.workspaceList.selectedServerId == "local")

        let duplicate = try second.controller.addRemote(host: "http://mac-mini.tailnet.ts.net:49361")
        #expect(duplicate == remote)
        #expect(second.controller.machines.filter { $0 == remote }.count == 1)
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

    @Test("Removing the selected remote falls back to local")
    func removeSelectedRemote() throws {
        let (controller, workspaceList, _) = makeController()
        let remote = try controller.addRemote(host: "10.0.0.5")

        try controller.removeMachine(remote.id)

        #expect(controller.selectedMachine == .local)
        #expect(controller.machines == [.local])
        #expect(workspaceList.selectedServerId == "local")
        #expect(throws: MachineControllerError.cannotRemoveLocal) {
            try controller.removeMachine("local")
        }
    }

    @Test("Server events keep workspaces and sessions in sync across clients")
    func eventSyncRefreshesAndRemoves() async throws {
        let workspaceId = UUID()
        let sessionId = UUID()
        let fake = SyncFakeServerClient(
            workspaces: [
                ServerWorkspace(
                    id: workspaceId.uuidString,
                    name: "Shared",
                    folderPath: "/tmp/shared",
                    isArchived: false,
                    symbolName: "folder",
                    origin: .herdman,
                    createdAt: "2026-06-30T00:00:00.000Z"
                )
            ],
            sessions: []
        )
        let workspaceList = WorkspaceListModel(
            workspaceRepository: DefaultWorkspaceRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            workspaceList: workspaceList,
            clientFactory: { _ in fake }
        )

        // Another client creates a session on the same server.
        controller.startEventSync()
        fake.setSessions([
            ServerSession(
                id: sessionId.uuidString,
                workspaceId: workspaceId.uuidString,
                serverId: "local",
                harnessId: "claude-code",
                agentSessionId: nil,
                title: "From another client",
                origin: .herdman,
                isArchived: false,
                createdAt: "2026-06-30T00:00:01.000Z",
                updatedAt: nil,
                usage: nil
            )
        ])
        fake.emit(kind: "session.created", subjectId: sessionId.uuidString)
        try await waitForSync { workspaceList.sessions.contains { $0.id == sessionId } }
        #expect(workspaceList.workspaces.contains { $0.id == workspaceId })

        // Another client deletes the session, then the workspace.
        fake.setSessions([])
        fake.emit(kind: "session.deleted", subjectId: sessionId.uuidString)
        try await waitForSync { !workspaceList.sessions.contains { $0.id == sessionId } }

        fake.emit(kind: "workspace.deleted", subjectId: workspaceId.uuidString)
        try await waitForSync { !workspaceList.workspaces.contains { $0.id == workspaceId } }

        controller.stopEventSync()
    }

    @Test("Client-triggered server update waits for the restart and reconnects")
    func remoteServerUpdate() async throws {
        let fake = SyncFakeServerClient(workspaces: [], sessions: [])
        fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
        let workspaceList = WorkspaceListModel(
            workspaceRepository: DefaultWorkspaceRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            workspaceList: workspaceList,
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

    private func waitForSync(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for sync condition")
    }

    private func makeController(store: InMemoryStore = InMemoryStore()) -> (
        controller: MachineController,
        workspaceList: WorkspaceListModel,
        store: InMemoryStore
    ) {
        let workspaceList = WorkspaceListModel(
            workspaceRepository: DefaultWorkspaceRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(store: store, workspaceList: workspaceList)
        return (controller, workspaceList, store)
    }
}

/// A fake server whose event stream and list endpoints are test-driven.
private final class SyncFakeServerClient: HerdManServerClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _workspaces: [ServerWorkspace]
    private var _sessions: [ServerSession]
    private var continuations: [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation] = []
    private var emittedEvents: [ServerEventEnvelope] = []
    private var nextEventId = 1

    init(workspaces: [ServerWorkspace], sessions: [ServerSession]) {
        _workspaces = workspaces
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

    func listWorkspaces() async throws -> [ServerWorkspace] { lock.withLock { _workspaces } }
    func listSessions() async throws -> [ServerSession] { lock.withLock { _sessions } }

    // MARK: - Simulated server versioning / self-update

    private var currentVersion = "0.1.0"
    private var latestVersion = "0.1.0"
    private var downtimeRemaining = 0
    private var _appliedUpdates = 0

    struct ServerDownError: Error {}

    var appliedUpdates: Int { lock.withLock { _appliedUpdates } }

    /// Makes the fake report an available update to `latest`.
    func configureUpdate(current: String, latest: String) {
        lock.withLock {
            currentVersion = current
            latestVersion = latest
        }
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
    func upsertWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace { fatalError("unused") }
    func updateWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace { fatalError("unused") }
    func deleteWorkspace(id: UUID) async throws {}
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
