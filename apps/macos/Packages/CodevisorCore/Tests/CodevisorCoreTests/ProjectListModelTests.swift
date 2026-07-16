import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

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

    @Test("Server project locations adopt the client's machine id, not the server's")
    func projectMappingStampsClientMachineId() throws {
        // The server always reports its own id as "local"; the client must
        // re-stamp the location with the machine id it's talking to, or
        // `location(for:)` misses and isGitRepository/worktrees break on
        // remote machines.
        let server = ServerProject(
            id: UUID().uuidString,
            name: "widget",
            isArchived: false,
            symbolName: "folder.fill",
            origin: .codevisor,
            createdAt: "2026-07-03T00:00:00.000Z",
            locations: [
                ServerProjectLocation(
                    id: "loc-1",
                    projectId: "ignored",
                    serverId: "local",
                    folderPath: "/root/.codevisor/repos/widget",
                    createdAt: "2026-07-03T00:00:00.000Z",
                    isGitRepository: true
                )
            ]
        )
        let project = try server.project(serverId: "vmi3431000.tail6fc9a.ts.net-49361")
        #expect(project.serverId == "vmi3431000.tail6fc9a.ts.net-49361")
        #expect(project.locations.first?.serverId == "vmi3431000.tail6fc9a.ts.net-49361")
        // The git flag now resolves, so the worktree option is available.
        #expect(project.isGitRepository)
    }

    @Test("adoptServerProject registers a clone under the server's project id")
    func adoptServerProjectUsesServerId() {
        let (model, _, _) = makeModel()
        let id = UUID()
        let url = URL(fileURLWithPath: "/home/user/.codevisor/repos/widget")

        let project = model.adoptServerProject(id: id, folderURL: url, name: "widget")
        #expect(project.id == id)
        #expect(project.name == "widget")
        #expect(project.folderURL == url)
        #expect(project.locations.allSatisfy { $0.projectId == id })

        // Adopting the same project again reuses (and un-archives) the entry.
        model.archive(project)
        let again = model.adoptServerProject(id: id, folderURL: url, name: "widget")
        #expect(again.id == id)
        #expect(again.isArchived == false)
        #expect(model.projects.filter { $0.id == id }.count == 1)
    }

    @Test("setWorktree patches a draft's worktree name and cwd locally")
    func setWorktreePatchesDraft() {
        let (model, _, sessionStore) = makeModel()
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/repo"))
        let session = model.newSession(in: project, title: "Draft", harnessId: "codex", syncToServer: false)
        #expect(model.sessions.first?.worktreeName == nil)

        model.setWorktree(
            name: "fearless-raven", cwd: "/tmp/worktrees/fearless-raven",
            for: session.id, serverId: session.serverId
        )

        let updated = model.sessions.first { $0.id == session.id }
        #expect(updated?.worktreeName == "fearless-raven")
        #expect(updated?.cwd == "/tmp/worktrees/fearless-raven")
        // Persisted, so the record survives a reload.
        let reloaded = DefaultSessionRepository(store: sessionStore).load()
        #expect(reloaded.first { $0.id == session.id }?.worktreeName == "fearless-raven")

        // Unknown ids are ignored.
        model.setWorktree(name: "other", cwd: "/tmp/x", for: UUID(), serverId: session.serverId)
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

    @Test("Server refresh replaces stale local records without pushing them back")
    func serverRefreshUsesServerAuthority() async throws {
        let (model, _, _) = makeModel()
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/offline"))
        let session = model.newSession(in: project, title: "Offline chat", harnessId: "codex", syncToServer: false)
        model.setAgentSessionId("agent-offline", for: session.id, serverId: session.serverId)

        let fakeServer = FakeServerClient()
        model.selectServer(serverId: "local", serverClient: fakeServer)

        try await waitUntil { model.projects.isEmpty && model.sessions.isEmpty }
        let snapshot = await fakeServer.snapshot()
        #expect(!snapshot.upsertedProjectIDs.contains(project.id.uuidString))
        #expect(!snapshot.upsertedSessionIDs.contains(session.id.uuidString))
    }

    @Test("Server refresh preserves a new local session until creation is acknowledged")
    func serverRefreshPreservesPendingSession() async throws {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/pending-session"))
        let fakeServer = FakeServerClient(projects: [serverProject(from: project)])
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )
        try await waitUntil { model.projects.contains { $0.id == project.id } }

        // First-send promotion is local and immediate; the controller creates
        // the server row after agent startup, so an intervening empty snapshot
        // must not remove the selected session.
        let session = model.newSession(
            in: project,
            title: "First prompt",
            harnessId: "codex",
            syncToServer: false
        )
        await model.refreshFromServer()
        #expect(model.sessions.contains { $0.id == session.id })

        // Once the server exposes the row, the normal authoritative copy wins
        // and no duplicate optimistic record remains.
        _ = try await fakeServer.upsertSession(session)
        await model.refreshFromServer()
        #expect(model.sessions.filter { $0.id == session.id }.count == 1)
    }

    @Test("Legacy JSON metadata is uploaded exactly once before server authority takes over")
    func legacyCacheMigratesOnce() async throws {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/legacy-project"))
        let session = ChatSession(
            projectId: project.id,
            harnessId: "codex",
            agentSessionId: "legacy-agent-session",
            title: "Legacy chat"
        )
        let projectStore = InMemoryStore()
        let sessionStore = InMemoryStore()
        let migrationStore = InMemoryStore()
        DefaultProjectRepository(store: projectStore).save([project])
        DefaultSessionRepository(store: sessionStore).save([session])
        let server = FakeServerClient()
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: projectStore),
            sessionRepository: DefaultSessionRepository(store: sessionStore),
            serverClient: server,
            legacyMigrationStore: migrationStore
        )

        try await waitUntil {
            migrationStore.loadData(forKey: "server-authority-v1-local") != nil
        }
        var snapshot = await server.snapshot()
        #expect(snapshot.upsertedProjectIDs == [project.id.uuidString])
        #expect(snapshot.upsertedSessionIDs == [session.id.uuidString])
        #expect(migrationStore.loadData(forKey: "server-authority-v1-local") != nil)

        await model.refreshFromServer()
        snapshot = await server.snapshot()
        #expect(snapshot.upsertedProjectIDs == [project.id.uuidString])
        #expect(snapshot.upsertedSessionIDs == [session.id.uuidString])
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

    @Test("Identical project and session ids stay isolated between machines")
    func duplicateIdsStayMachineScoped() {
        let projectId = UUID()
        let sessionId = UUID()
        let localProject = Project(
            id: projectId, serverId: "local", name: "Local",
            locations: [ProjectLocation(projectId: projectId, serverId: "local", folderPath: "/local")]
        )
        let remoteProject = Project(
            id: projectId, serverId: "remote-a", name: "Remote",
            locations: [ProjectLocation(projectId: projectId, serverId: "remote-a", folderPath: "/remote")]
        )
        let localSession = ChatSession(
            id: sessionId, projectId: projectId, serverId: "local", harnessId: "codex", title: "Local chat"
        )
        let remoteSession = ChatSession(
            id: sessionId, projectId: projectId, serverId: "remote-a", harnessId: "codex", title: "Remote chat"
        )
        let projectStore = InMemoryStore()
        let sessionStore = InMemoryStore()
        DefaultProjectRepository(store: projectStore).save([localProject, remoteProject])
        DefaultSessionRepository(store: sessionStore).save([localSession, remoteSession])
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: projectStore),
            sessionRepository: DefaultSessionRepository(store: sessionStore)
        )

        model.archive(remoteProject)
        model.renameSession(remoteSession, to: "Renamed remote")

        #expect(model.projects.first { $0.serverId == "local" }?.isArchived == false)
        #expect(model.projects.first { $0.serverId == "remote-a" }?.isArchived == true)
        #expect(model.sessions.first { $0.serverId == "local" }?.title == "Local chat")
        #expect(model.sessions.first { $0.serverId == "remote-a" }?.title == "Renamed remote")

        model.removeProjectLocally(id: projectId, serverId: "remote-a")
        #expect(model.projects.contains { $0.serverId == "local" && $0.id == projectId })
        #expect(model.sessions.contains { $0.serverId == "local" && $0.id == sessionId })
        #expect(!model.projects.contains { $0.serverId == "remote-a" && $0.id == projectId })
        #expect(!model.sessions.contains { $0.serverId == "remote-a" && $0.id == sessionId })
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

    @Test("Re-importing a known session advances its activity without overwriting metadata")
    func reimportAdvancesKnownSessionActivity() {
        let (model, _, sessionStore) = makeModel()
        model.showsImportedSessions = true
        let oldTimestamp = "2026-06-01T00:00:00Z"
        // Native scanners return JavaScript ISO strings with fractional
        // seconds, so exercise the exact format used by the server endpoint.
        let newTimestamp = "2026-06-03T00:00:00.123Z"

        model.importSessions([
            ImportedSession(
                harnessId: "codex",
                info: SessionInfo(sessionId: "ext-1", cwd: "/tmp/a", title: "Agent title", updatedAt: oldTimestamp)
            )
        ], serverId: "local")
        let project = model.projects.first!
        let imported = model.sessions(in: project).first!
        model.renameSession(imported, to: "My title")

        model.importSessions([
            ImportedSession(
                harnessId: "codex",
                info: SessionInfo(sessionId: "ext-1", cwd: "/tmp/a", title: "Changed agent title", updatedAt: newTimestamp)
            )
        ], serverId: "local")

        let refreshed = model.sessions(in: project).first!
        #expect(model.sessions.count == 1)
        #expect(refreshed.title == "My title")
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(refreshed.updatedAt == fractionalFormatter.date(from: newTimestamp))
        let persisted = DefaultSessionRepository(store: sessionStore).load().first!
        #expect(persisted.updatedAt == refreshed.updatedAt)

        // An older scanner result must never roll server/app activity back.
        model.importSessions([
            ImportedSession(
                harnessId: "codex",
                info: SessionInfo(sessionId: "ext-1", cwd: "/tmp/a", updatedAt: oldTimestamp)
            )
        ], serverId: "local")
        #expect(model.sessions(in: project).first?.updatedAt == refreshed.updatedAt)
    }

    @Test("A machine switch during an in-flight refresh does not re-tag the old machine's projects")
    func refreshDroppedAfterMachineSwitch() async throws {
        let remoteProject = Project.fromFolder(
            URL(fileURLWithPath: "/srv/remote-only"),
            createdAt: Date(timeIntervalSince1970: 5)
        )
        let (model, projectStore, _) = makeModel()
        let latch = Latch()
        let remoteServer = FakeServerClient(projects: [serverProject(from: remoteProject)])
        await remoteServer.setListDelay { await latch.wait() }

        // Start a refresh against the remote machine, then switch back to
        // local while its list call is still in flight (a slow network hop).
        model.selectServer(serverId: "remote-mac-mini", serverClient: remoteServer)
        try await Task.sleep(nanoseconds: 20_000_000)
        model.selectServer(serverId: "local", serverClient: FakeServerClient())
        await latch.open()
        try await Task.sleep(nanoseconds: 50_000_000)

        // The stale remote response must never be filed under "local" — that
        // would put another machine's projects in the local sidebar forever.
        #expect(!model.projects.contains { $0.id == remoteProject.id && $0.serverId == "local" })
        #expect(model.activeProjects.isEmpty)
        let persisted = DefaultProjectRepository(store: projectStore).load()
        #expect(!persisted.contains { $0.id == remoteProject.id && $0.serverId == "local" })
    }

    @Test("Imports are filed under the machine they were discovered on, not the current selection")
    func importTagsDiscoveryServer() {
        // Discovery ran against the remote machine, but the user has since
        // switched to local: the results still belong to the remote machine.
        let (model, _, _) = makeModel()
        model.showsImportedSessions = true
        model.importSessions([
            ImportedSession(harnessId: "codex", info: SessionInfo(sessionId: "r-1", cwd: "/srv/proj", title: "Remote"))
        ], serverId: "remote-mac-mini")

        #expect(model.projects.allSatisfy { $0.serverId == "remote-mac-mini" })
        #expect(model.sessions.allSatisfy { $0.serverId == "remote-mac-mini" })
        // Nothing leaks into the (selected) local sidebar.
        #expect(model.activeProjects.isEmpty)
    }

    @Test("Sessions imported into a project inherit the project's machine")
    func importIntoProjectInheritsProjectServer() {
        let (model, _, _) = makeModel()
        model.showsImportedSessions = true
        // The project was added while the remote machine was selected.
        model.selectServer(serverId: "remote-mac-mini", serverClient: nil, refresh: false)
        let project = model.addProject(folderURL: URL(fileURLWithPath: "/srv/proj"))
        model.selectServer(serverId: "local", serverClient: nil, refresh: false)

        // Confirming a pending import after switching back to local must not
        // re-tag the sessions to the local machine.
        model.importSessions([
            ImportedSession(harnessId: "codex", info: SessionInfo(sessionId: "r-2", cwd: "/srv/proj", title: "Remote"))
        ], into: project)

        #expect(model.sessions.allSatisfy { $0.serverId == "remote-mac-mini" })
        #expect(model.activeProjects.isEmpty)
    }
}

/// A reusable gate: `wait()` suspends callers until `open()` is called.
private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
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

private actor FakeServerClient: CodevisorServerClienting {
    private var projects: [ServerProject]
    private var sessions: [ServerSession]
    private var upsertedProjectIDs: [String] = []
    private var upsertedSessionIDs: [String] = []
    private var deletedProjectIDs: [String] = []
    private var deletedSessionIDs: [String] = []
    /// When set, `listProjects` suspends on this first — lets tests hold a
    /// "network" call in flight while the app state changes underneath it.
    private var listDelay: (@Sendable () async -> Void)?

    init(projects: [ServerProject] = [], sessions: [ServerSession] = []) {
        self.projects = projects
        self.sessions = sessions
    }

    func setListDelay(_ delay: @escaping @Sendable () async -> Void) {
        listDelay = delay
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

    func listProjects() async throws -> [ServerProject] {
        if let listDelay { await listDelay() }
        return projects
    }

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
