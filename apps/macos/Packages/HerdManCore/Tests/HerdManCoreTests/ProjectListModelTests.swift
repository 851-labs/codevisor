import Foundation
import Testing
import ACPKit
@testable import HerdManCore

@MainActor
@Suite("ProjectListModel")
struct ProjectListModelTests {
    private func makeModel() -> (ProjectListModel, InMemoryStore, InMemoryStore) {
        let projectStore = InMemoryStore()
        let sessionStore = InMemoryStore()
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: projectStore),
            sessionRepository: DefaultSessionRepository(store: sessionStore)
        )
        return (model, projectStore, sessionStore)
    }

    @Test("setWorktree patches a draft's worktree name and cwd locally")
    func setWorktreePatchesDraft() {
        let (model, _, sessionStore) = makeModel()
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/repo"))
        let session = model.newSession(in: project, title: "Draft", harnessId: "codex", syncToServer: false)
        #expect(model.sessions.first?.worktreeName == nil)

        model.setWorktree(name: "fearless-raven", cwd: "/tmp/worktrees/fearless-raven", for: session.id)

        let updated = model.sessions.first { $0.id == session.id }
        #expect(updated?.worktreeName == "fearless-raven")
        #expect(updated?.cwd == "/tmp/worktrees/fearless-raven")
        // Persisted, so the record survives a reload.
        let reloaded = DefaultSessionRepository(store: sessionStore).load()
        #expect(reloaded.first { $0.id == session.id }?.worktreeName == "fearless-raven")

        // Unknown ids are ignored.
        model.setWorktree(name: "other", cwd: "/tmp/x", for: UUID())
        #expect(model.sessions.first { $0.id == session.id }?.worktreeName == "fearless-raven")
    }

    @Test("Server refresh merges remote projects and sessions into the local cache")
    func serverRefresh() async throws {
        let project = Project.fromFolder(
            URL(fileURLWithPath: "/tmp/remote"),
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let remoteSession = ChatSession(
            id: UUID(),
            projectId: project.id,
            serverId: "mac-mini",
            harnessId: "codex",
            agentSessionId: "agent-remote",
            title: "Remote session",
            createdAt: Date(timeIntervalSince1970: 11)
        )
        let scopedSession = ChatSession(
            id: remoteSession.id,
            projectId: project.id,
            serverId: "local",
            harnessId: remoteSession.harnessId,
            agentSessionId: remoteSession.agentSessionId,
            title: remoteSession.title,
            createdAt: remoteSession.createdAt
        )
        let fakeServer = FakeServerClient(
            projects: [serverProject(from: project)],
            sessions: [serverSession(from: remoteSession)]
        )
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )

        try await waitUntil {
            model.projects.contains(project) && model.sessions.contains(scopedSession)
        }
    }

    @Test("Server refresh pushes local-only records up to the server")
    func serverRefreshPushesLocalOnlyRecords() async throws {
        // Created while no server was reachable: cache-only until a refresh.
        let (model, _, _) = makeModel()
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/offline"))
        let session = model.newSession(in: project, title: "Offline chat", harnessId: "codex", syncToServer: false)
        model.setAgentSessionId("agent-offline", for: session.id)

        let fakeServer = FakeServerClient()
        model.selectServer(serverId: "local", serverClient: fakeServer)

        var pushed = false
        for _ in 0..<50 where !pushed {
            let snapshot = await fakeServer.snapshot()
            pushed = snapshot.upsertedProjectIDs.contains(project.id.uuidString)
                && snapshot.upsertedSessionIDs.contains(session.id.uuidString)
            if !pushed {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        #expect(pushed, "local-only project and session should be upserted to the server")
    }

    @Test("Server refresh is scoped to the selected machine")
    func serverRefreshScopesToSelectedMachine() async throws {
        let localProject = Project.fromFolder(
            URL(fileURLWithPath: "/tmp/local"),
            serverId: "local",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let remoteProject = Project.fromFolder(
            URL(fileURLWithPath: "/srv/remote"),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let remoteSession = ChatSession(
            id: UUID(),
            projectId: remoteProject.id,
            serverId: "server-internal-id",
            harnessId: "codex",
            title: "Remote",
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let projectStore = InMemoryStore()
        let sessionStore = InMemoryStore()
        DefaultProjectRepository(store: projectStore).save([localProject])
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: projectStore),
            sessionRepository: DefaultSessionRepository(store: sessionStore),
            serverClient: FakeServerClient()
        )
        let remoteServer = FakeServerClient(
            projects: [serverProject(from: remoteProject)],
            sessions: [serverSession(from: remoteSession)]
        )

        model.selectServer(serverId: "remote-mac-mini", serverClient: remoteServer)

        try await waitUntil {
            model.projects.contains { $0.id == localProject.id && $0.serverId == "local" }
                && model.projects.contains { $0.id == remoteProject.id && $0.serverId == "remote-mac-mini" }
                && model.sessions.contains { $0.id == remoteSession.id && $0.serverId == "remote-mac-mini" }
        }
        #expect(model.activeProjects.map(\.id) == [remoteProject.id])
    }

    @Test("Local mutations are mirrored to the configured server")
    func serverMutationMirroring() async throws {
        let fakeServer = FakeServerClient()
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/mirrored"))
        let session = model.newSession(in: project, title: "First", harnessId: "codex")
        model.renameSession(session, to: "Renamed")
        model.deleteSession(session)
        model.removeProject(project)

        for _ in 0..<50 {
            let snapshot = await fakeServer.snapshot()
            if snapshot.upsertedProjectIDs.contains(project.id.uuidString),
               snapshot.upsertedSessionIDs.contains(session.id.uuidString),
               snapshot.deletedSessionIDs.contains(session.id.uuidString),
               snapshot.deletedProjectIDs.contains(project.id.uuidString) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for server mirror calls")
    }

    @Test("Draft sessions can be held locally until first send")
    func draftSessionSkipsImmediateServerSync() async throws {
        let fakeServer = FakeServerClient()
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )

        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/draft"))
        _ = model.newSession(in: project, title: "Draft", harnessId: "codex", syncToServer: false)
        try await Task.sleep(nanoseconds: 20_000_000)

        let snapshot = await fakeServer.snapshot()
        #expect(snapshot.upsertedSessionIDs.isEmpty)
    }

    @Test("Adding a folder creates and persists a project")
    func addProject() {
        let (model, store, _) = makeModel()
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/proj"))
        #expect(project.name == "proj")
        #expect(model.projects.count == 1)
        // Persisted: a fresh model reads it back.
        let reloaded = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: store),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        #expect(reloaded.projects.count == 1)
    }

    @Test("Adding the same folder twice does not duplicate and un-archives")
    func addDeduplicates() {
        let (model, _, _) = makeModel()
        let url = URL(fileURLWithPath: "/tmp/proj")
        let first = model.addProject(folderURL: url)
        model.archive(first)
        let second = model.addProject(folderURL: url)
        #expect(model.projects.count == 1)
        #expect(second.id == first.id)
        #expect(second.isArchived == false)
    }

    @Test("Archiving moves a project between sections")
    func archiving() {
        let (model, _, _) = makeModel()
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"))
        #expect(model.activeProjects.count == 1)
        #expect(model.hasArchivedProjects == false)

        model.archive(project)
        #expect(model.activeProjects.isEmpty)
        #expect(model.archivedProjects.count == 1)
        #expect(model.hasArchivedProjects)

        model.unarchive(project)
        #expect(model.activeProjects.count == 1)
        #expect(model.hasArchivedProjects == false)
    }

    @Test("Active and archived projects are sorted newest-first")
    func sorting() {
        let store = InMemoryStore()
        let repository = DefaultProjectRepository(store: store)
        repository.save([
            Project(name: "old", createdAt: Date(timeIntervalSince1970: 1)),
            Project(name: "new", createdAt: Date(timeIntervalSince1970: 9))
        ])
        let model = ProjectListModel(
            projectRepository: repository,
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        #expect(model.activeProjects.map(\.name) == ["new", "old"])
    }

    @Test("New sessions are scoped to a project and persisted")
    func sessions() {
        let (model, _, sessionStore) = makeModel()
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"))
        let other = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/b"))
        let session = model.newSession(in: project, title: "First", harnessId: "claude")
        model.newSession(in: other)
        #expect(model.sessions(in: project).map(\.id) == [session.id])

        // Persisted.
        let reloaded = DefaultSessionRepository(store: sessionStore).load()
        #expect(reloaded.count == 2)
    }

    @Test("Renaming and deleting sessions update state")
    func renameDelete() {
        let (model, _, _) = makeModel()
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"))
        let session = model.newSession(in: project)
        model.renameSession(session, to: "Renamed")
        #expect(model.sessions(in: project).first?.title == "Renamed")
        model.deleteSession(session)
        #expect(model.sessions(in: project).isEmpty)
    }

    @Test("Archiving a session hides it from the active list but keeps it")
    func archiveSession() {
        let (model, _, sessionStore) = makeModel()
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"))
        let session = model.newSession(in: project)
        model.archiveSession(session)
        #expect(model.sessions(in: project).isEmpty)
        // Still persisted (not deleted).
        #expect(DefaultSessionRepository(store: sessionStore).load().contains { $0.id == session.id && $0.isArchived })
    }

    @Test("Removing a project also removes its sessions")
    func removeProject() {
        let (model, _, _) = makeModel()
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"))
        model.newSession(in: project)
        model.removeProject(project)
        #expect(model.projects.isEmpty)
        #expect(model.sessions.isEmpty)
    }

    @Test("Importing sessions into a project skips known ones and persists")
    func importIntoProject() {
        let (model, _, sessionStore) = makeModel()
        model.showsImportedSessions = true
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"))
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

        model.importSessions(imported, into: project)
        // Importing the same discoveries again must not duplicate anything.
        model.importSessions(imported, into: project)

        let sessions = model.sessions(in: project)
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
    var upsertedProjectIDs: [String]
    var upsertedSessionIDs: [String]
    var deletedProjectIDs: [String]
    var deletedSessionIDs: [String]
}

private actor FakeServerClient: HerdManServerClienting {
    private var projects: [ServerProject]
    private var sessions: [ServerSession]
    private var upsertedProjectIDs: [String] = []
    private var upsertedSessionIDs: [String] = []
    private var deletedProjectIDs: [String] = []
    private var deletedSessionIDs: [String] = []

    init(projects: [ServerProject] = [], sessions: [ServerSession] = []) {
        self.projects = projects
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

    func listProjects() async throws -> [ServerProject] { projects }

    func upsertProject(_ project: Project) async throws -> ServerProject {
        let serverProject = serverProject(from: project)
        upsertedProjectIDs.append(serverProject.id)
        projects.removeAll { $0.id == serverProject.id }
        projects.append(serverProject)
        return serverProject
    }

    func updateProject(_ project: Project) async throws -> ServerProject {
        try await upsertProject(project)
    }

    func deleteProject(id: UUID) async throws {
        deletedProjectIDs.append(id.uuidString)
        projects.removeAll { $0.id == id.uuidString }
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
            upsertedProjectIDs: upsertedProjectIDs,
            upsertedSessionIDs: upsertedSessionIDs,
            deletedProjectIDs: deletedProjectIDs,
            deletedSessionIDs: deletedSessionIDs
        )
    }
}

private func serverProject(from project: Project) -> ServerProject {
    ServerProject(
        id: project.id.uuidString,
        name: project.name,
        isArchived: project.isArchived,
        symbolName: project.symbolName,
        origin: project.origin,
        createdAt: serverDateString(from: project.createdAt),
        locations: project.locations.map { location in
            ServerProjectLocation(
                id: location.id,
                projectId: project.id.uuidString,
                serverId: location.serverId,
                folderPath: location.folderPath,
                createdAt: serverDateString(from: project.createdAt),
                isGitRepository: location.isGitRepository
            )
        }
    )
}

private func serverSession(from session: ChatSession) -> ServerSession {
    ServerSession(
        id: session.id.uuidString,
        projectId: session.projectId.uuidString,
        serverId: session.serverId,
        harnessId: session.harnessId,
        agentSessionId: session.agentSessionId,
        title: session.title,
        origin: session.origin,
        isArchived: session.isArchived,
        worktreeName: session.worktreeName,
        cwd: session.cwd,
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
