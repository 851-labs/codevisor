import Foundation
import Testing
import ACPKit
@testable import HerdManCore

@MainActor
@Suite("WorkspaceListModel")
struct WorkspaceListModelTests {
    private func makeModel() -> (WorkspaceListModel, InMemoryStore, InMemoryStore) {
        let workspaceStore = InMemoryStore()
        let sessionStore = InMemoryStore()
        let model = WorkspaceListModel(
            workspaceRepository: DefaultWorkspaceRepository(store: workspaceStore),
            sessionRepository: DefaultSessionRepository(store: sessionStore)
        )
        return (model, workspaceStore, sessionStore)
    }

    @Test("Server refresh merges remote workspaces and sessions into the local cache")
    func serverRefresh() async throws {
        let workspace = Workspace(
            id: UUID(),
            name: "Remote",
            folderURL: URL(fileURLWithPath: "/tmp/remote"),
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let remoteSession = ChatSession(
            id: UUID(),
            workspaceId: workspace.id,
            serverId: "mac-mini",
            harnessId: "codex",
            agentSessionId: "agent-remote",
            title: "Remote session",
            createdAt: Date(timeIntervalSince1970: 11)
        )
        let scopedSession = ChatSession(
            id: remoteSession.id,
            workspaceId: workspace.id,
            serverId: "local",
            harnessId: remoteSession.harnessId,
            agentSessionId: remoteSession.agentSessionId,
            title: remoteSession.title,
            createdAt: remoteSession.createdAt
        )
        let fakeServer = FakeServerClient(
            workspaces: [serverWorkspace(from: workspace)],
            sessions: [serverSession(from: remoteSession)]
        )
        let model = WorkspaceListModel(
            workspaceRepository: DefaultWorkspaceRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )

        try await waitUntil {
            model.workspaces.contains(workspace) && model.sessions.contains(scopedSession)
        }
    }

    @Test("Server refresh pushes local-only records up to the server")
    func serverRefreshPushesLocalOnlyRecords() async throws {
        // Created while no server was reachable: cache-only until a refresh.
        let (model, _, _) = makeModel()
        let workspace = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/offline"))
        let session = model.newSession(in: workspace, title: "Offline chat", harnessId: "codex", syncToServer: false)
        model.setAgentSessionId("agent-offline", for: session.id)

        let fakeServer = FakeServerClient()
        model.selectServer(serverId: "local", serverClient: fakeServer)

        var pushed = false
        for _ in 0..<50 where !pushed {
            let snapshot = await fakeServer.snapshot()
            pushed = snapshot.upsertedWorkspaceIDs.contains(workspace.id.uuidString)
                && snapshot.upsertedSessionIDs.contains(session.id.uuidString)
            if !pushed {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        #expect(pushed, "local-only workspace and session should be upserted to the server")
    }

    @Test("Server refresh is scoped to the selected machine")
    func serverRefreshScopesToSelectedMachine() async throws {
        let localWorkspace = Workspace(
            id: UUID(),
            serverId: "local",
            name: "Local",
            folderURL: URL(fileURLWithPath: "/tmp/local"),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let remoteWorkspace = Workspace(
            id: UUID(),
            name: "Remote",
            folderURL: URL(fileURLWithPath: "/srv/remote"),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let remoteSession = ChatSession(
            id: UUID(),
            workspaceId: remoteWorkspace.id,
            serverId: "server-internal-id",
            harnessId: "codex",
            title: "Remote",
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let workspaceStore = InMemoryStore()
        let sessionStore = InMemoryStore()
        DefaultWorkspaceRepository(store: workspaceStore).save([localWorkspace])
        let model = WorkspaceListModel(
            workspaceRepository: DefaultWorkspaceRepository(store: workspaceStore),
            sessionRepository: DefaultSessionRepository(store: sessionStore),
            serverClient: FakeServerClient()
        )
        let remoteServer = FakeServerClient(
            workspaces: [serverWorkspace(from: remoteWorkspace)],
            sessions: [serverSession(from: remoteSession)]
        )

        model.selectServer(serverId: "remote-mac-mini", serverClient: remoteServer)

        try await waitUntil {
            model.workspaces.contains { $0.id == localWorkspace.id && $0.serverId == "local" }
                && model.workspaces.contains { $0.id == remoteWorkspace.id && $0.serverId == "remote-mac-mini" }
                && model.sessions.contains { $0.id == remoteSession.id && $0.serverId == "remote-mac-mini" }
        }
        #expect(model.activeWorkspaces.map(\.id) == [remoteWorkspace.id])
    }

    @Test("Local mutations are mirrored to the configured server")
    func serverMutationMirroring() async throws {
        let fakeServer = FakeServerClient()
        let model = WorkspaceListModel(
            workspaceRepository: DefaultWorkspaceRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )
        let workspace = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/mirrored"))
        let session = model.newSession(in: workspace, title: "First", harnessId: "codex")
        model.renameSession(session, to: "Renamed")
        model.deleteSession(session)
        model.removeWorkspace(workspace)

        for _ in 0..<50 {
            let snapshot = await fakeServer.snapshot()
            if snapshot.upsertedWorkspaceIDs.contains(workspace.id.uuidString),
               snapshot.upsertedSessionIDs.contains(session.id.uuidString),
               snapshot.deletedSessionIDs.contains(session.id.uuidString),
               snapshot.deletedWorkspaceIDs.contains(workspace.id.uuidString) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for server mirror calls")
    }

    @Test("Draft sessions can be held locally until first send")
    func draftSessionSkipsImmediateServerSync() async throws {
        let fakeServer = FakeServerClient()
        let model = WorkspaceListModel(
            workspaceRepository: DefaultWorkspaceRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )

        let workspace = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/draft"))
        _ = model.newSession(in: workspace, title: "Draft", harnessId: "codex", syncToServer: false)
        try await Task.sleep(nanoseconds: 20_000_000)

        let snapshot = await fakeServer.snapshot()
        #expect(snapshot.upsertedSessionIDs.isEmpty)
    }

    @Test("Adding a folder creates and persists a workspace")
    func addWorkspace() {
        let (model, store, _) = makeModel()
        let workspace = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/proj"))
        #expect(workspace.name == "proj")
        #expect(model.workspaces.count == 1)
        // Persisted: a fresh model reads it back.
        let reloaded = WorkspaceListModel(
            workspaceRepository: DefaultWorkspaceRepository(store: store),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        #expect(reloaded.workspaces.count == 1)
    }

    @Test("Adding the same folder twice does not duplicate and un-archives")
    func addDeduplicates() {
        let (model, _, _) = makeModel()
        let url = URL(fileURLWithPath: "/tmp/proj")
        let first = model.addWorkspace(folderURL: url)
        model.archive(first)
        let second = model.addWorkspace(folderURL: url)
        #expect(model.workspaces.count == 1)
        #expect(second.id == first.id)
        #expect(second.isArchived == false)
    }

    @Test("Archiving moves a workspace between sections")
    func archiving() {
        let (model, _, _) = makeModel()
        let workspace = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"))
        #expect(model.activeWorkspaces.count == 1)
        #expect(model.hasArchivedWorkspaces == false)

        model.archive(workspace)
        #expect(model.activeWorkspaces.isEmpty)
        #expect(model.archivedWorkspaces.count == 1)
        #expect(model.hasArchivedWorkspaces)

        model.unarchive(workspace)
        #expect(model.activeWorkspaces.count == 1)
        #expect(model.hasArchivedWorkspaces == false)
    }

    @Test("Active and archived workspaces are sorted newest-first")
    func sorting() {
        let store = InMemoryStore()
        let repository = DefaultWorkspaceRepository(store: store)
        repository.save([
            Workspace(name: "old", folderURL: URL(fileURLWithPath: "/o"), createdAt: Date(timeIntervalSince1970: 1)),
            Workspace(name: "new", folderURL: URL(fileURLWithPath: "/n"), createdAt: Date(timeIntervalSince1970: 9))
        ])
        let model = WorkspaceListModel(
            workspaceRepository: repository,
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        #expect(model.activeWorkspaces.map(\.name) == ["new", "old"])
    }

    @Test("New sessions are scoped to a workspace and persisted")
    func sessions() {
        let (model, _, sessionStore) = makeModel()
        let workspace = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"))
        let other = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/b"))
        let session = model.newSession(in: workspace, title: "First", harnessId: "claude")
        model.newSession(in: other)
        #expect(model.sessions(in: workspace).map(\.id) == [session.id])

        // Persisted.
        let reloaded = DefaultSessionRepository(store: sessionStore).load()
        #expect(reloaded.count == 2)
    }

    @Test("Renaming and deleting sessions update state")
    func renameDelete() {
        let (model, _, _) = makeModel()
        let workspace = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"))
        let session = model.newSession(in: workspace)
        model.renameSession(session, to: "Renamed")
        #expect(model.sessions(in: workspace).first?.title == "Renamed")
        model.deleteSession(session)
        #expect(model.sessions(in: workspace).isEmpty)
    }

    @Test("Archiving a session hides it from the active list but keeps it")
    func archiveSession() {
        let (model, _, sessionStore) = makeModel()
        let workspace = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"))
        let session = model.newSession(in: workspace)
        model.archiveSession(session)
        #expect(model.sessions(in: workspace).isEmpty)
        // Still persisted (not deleted).
        #expect(DefaultSessionRepository(store: sessionStore).load().contains { $0.id == session.id && $0.isArchived })
    }

    @Test("Removing a workspace also removes its sessions")
    func removeWorkspace() {
        let (model, _, _) = makeModel()
        let workspace = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"))
        model.newSession(in: workspace)
        model.removeWorkspace(workspace)
        #expect(model.workspaces.isEmpty)
        #expect(model.sessions.isEmpty)
    }

    @Test("Importing sessions into a workspace skips known ones and persists")
    func importIntoWorkspace() {
        let (model, _, sessionStore) = makeModel()
        model.showsImportedSessions = true
        let workspace = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"))
        let imported = [
            ImportedSession(
                harnessId: "claude-code",
                info: SessionInfo(sessionId: "ext-1", cwd: "/tmp/a", title: "Old chat", updatedAt: "2026-06-01T00:00:00Z")
            ),
            ImportedSession(
                harnessId: "claude-code",
                info: SessionInfo(sessionId: "ext-2", cwd: "/tmp/a")
            )
        ]

        model.importSessions(imported, into: workspace)
        // Importing the same discoveries again must not duplicate anything.
        model.importSessions(imported, into: workspace)

        let sessions = model.sessions(in: workspace)
        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { $0.origin == .imported })
        #expect(sessions.contains { $0.agentSessionId == "ext-1" && $0.title == "Old chat" })
        #expect(sessions.contains { $0.agentSessionId == "ext-2" && $0.title == "Session" })
        #expect(DefaultSessionRepository(store: sessionStore).load().count == 2)
    }
}

@MainActor
private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<50 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for condition")
}

private struct FakeServerSnapshot: Sendable {
    var upsertedWorkspaceIDs: [String]
    var upsertedSessionIDs: [String]
    var deletedWorkspaceIDs: [String]
    var deletedSessionIDs: [String]
}

private actor FakeServerClient: HerdManServerClienting {
    private var workspaces: [ServerWorkspace]
    private var sessions: [ServerSession]
    private var upsertedWorkspaceIDs: [String] = []
    private var upsertedSessionIDs: [String] = []
    private var deletedWorkspaceIDs: [String] = []
    private var deletedSessionIDs: [String] = []

    init(workspaces: [ServerWorkspace] = [], sessions: [ServerSession] = []) {
        self.workspaces = workspaces
        self.sessions = sessions
    }

    func health() async throws -> ServerHealth {
        ServerHealth(ok: true, version: "0.1.0", database: "ready")
    }

    func info() async throws -> ServerInfo { fatalError("unused") }

    func updateInfo() async throws -> ServerUpdateInfo { fatalError("unused") }

    func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }

    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }

    func listHarnesses() async throws -> [ServerHarness] { [] }

    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }

    func listWorkspaces() async throws -> [ServerWorkspace] { workspaces }

    func upsertWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace {
        let serverWorkspace = serverWorkspace(from: workspace)
        upsertedWorkspaceIDs.append(serverWorkspace.id)
        workspaces.removeAll { $0.id == serverWorkspace.id }
        workspaces.append(serverWorkspace)
        return serverWorkspace
    }

    func updateWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace {
        try await upsertWorkspace(workspace)
    }

    func deleteWorkspace(id: UUID) async throws {
        deletedWorkspaceIDs.append(id.uuidString)
        workspaces.removeAll { $0.id == id.uuidString }
    }

    func listSessions() async throws -> [ServerSession] { sessions }

    func sessionDetail(id: UUID) async throws -> ServerSessionDetail {
        fatalError("unused")
    }

    func upsertSession(_ session: ChatSession) async throws -> ServerSession {
        let serverSession = serverSession(from: session)
        upsertedSessionIDs.append(serverSession.id)
        sessions.removeAll { $0.id == serverSession.id }
        sessions.append(serverSession)
        return serverSession
    }

    func updateSession(_ session: ChatSession) async throws -> ServerSession {
        try await upsertSession(session)
    }

    func deleteSession(id: UUID) async throws {
        deletedSessionIDs.append(id.uuidString)
        sessions.removeAll { $0.id == id.uuidString }
    }

    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
    }

    func cancelSession(id: UUID) async throws {}

    func setSessionMode(id: UUID, modeId: String) async throws {}

    func setSessionConfig(id: UUID, configId: String, value: String) async throws {}

    nonisolated func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func snapshot() -> FakeServerSnapshot {
        FakeServerSnapshot(
            upsertedWorkspaceIDs: upsertedWorkspaceIDs,
            upsertedSessionIDs: upsertedSessionIDs,
            deletedWorkspaceIDs: deletedWorkspaceIDs,
            deletedSessionIDs: deletedSessionIDs
        )
    }
}

private func serverWorkspace(from workspace: Workspace) -> ServerWorkspace {
    ServerWorkspace(
        id: workspace.id.uuidString,
        name: workspace.name,
        folderPath: workspace.folderURL.path,
        isArchived: workspace.isArchived,
        symbolName: workspace.symbolName,
        origin: workspace.origin,
        createdAt: serverDateString(from: workspace.createdAt)
    )
}

private func serverSession(from session: ChatSession) -> ServerSession {
    ServerSession(
        id: session.id.uuidString,
        workspaceId: session.workspaceId.uuidString,
        serverId: session.serverId,
        harnessId: session.harnessId,
        agentSessionId: session.agentSessionId,
        title: session.title,
        origin: session.origin,
        isArchived: session.isArchived,
        createdAt: serverDateString(from: session.createdAt),
        updatedAt: session.updatedAt.map(serverDateString),
        usage: nil
    )
}

private func serverDateString(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
