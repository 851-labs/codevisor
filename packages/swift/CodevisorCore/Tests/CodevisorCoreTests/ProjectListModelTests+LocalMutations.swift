import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
extension ProjectListModelTests {
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
                snapshot.deletedProjectIDs.contains(project.id.uuidString)
            {
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
            Project(name: "new", createdAt: Date(timeIntervalSince1970: 9)),
        ])
        let model = ProjectListModel(
            projectRepository: repository,
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        #expect(model.activeProjects.map(\.name) == ["new", "old"])
    }

    @Test("Active projects are ordered by their most recently created workspace")
    func workspaceRecencySorting() {
        let store = InMemoryStore()
        let repository = DefaultProjectRepository(store: store)
        let unusedOlder = Project(
            name: "unused-older",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let usedEarlier = Project(
            name: "used-earlier",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let usedLatest = Project(
            name: "used-latest",
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let unusedNewer = Project(
            name: "unused-newer",
            createdAt: Date(timeIntervalSince1970: 4)
        )
        repository.save([unusedOlder, usedEarlier, usedLatest, unusedNewer])
        let model = ProjectListModel(
            projectRepository: repository,
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )

        func workspace(
            projectId: UUID,
            createdAt: TimeInterval,
            serverId: String = "local"
        ) -> Workspace {
            Workspace(
                name: "Workspace",
                rootDirectory: nil,
                serverId: serverId,
                projectId: projectId,
                centerTree: .leaf(PaneGroupState()),
                bottomGroup: PaneGroupState(),
                createdAt: Date(timeIntervalSince1970: createdAt)
            )
        }

        let ordered = model.activeProjectsByWorkspaceRecency([
            workspace(projectId: usedEarlier.id, createdAt: 10),
            workspace(projectId: usedLatest.id, createdAt: 20),
            // The newest workspace per project wins, not the first one.
            workspace(projectId: usedEarlier.id, createdAt: 15),
            // Workspace history is scoped to the selected machine.
            workspace(projectId: unusedNewer.id, createdAt: 30, serverId: "remote"),
        ])

        #expect(
            ordered.map(\.name) == [
                "used-latest",
                "used-earlier",
                "unused-newer",
                "unused-older",
            ])
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
                info: SessionInfo(
                    sessionId: "ext-1", cwd: "/tmp/a", title: "Old chat", updatedAt: "2026-06-01T00:00:00Z")
            ),
            ImportedSession(
                harnessId: "claude-code",
                info: SessionInfo(sessionId: "ext-2", cwd: "/tmp/a")
            ),
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

        model.importSessions(
            [
                ImportedSession(
                    harnessId: "codex",
                    info: SessionInfo(sessionId: "ext-1", cwd: "/tmp/a", title: "Agent title", updatedAt: oldTimestamp)
                )
            ], serverId: "local")
        let project = model.projects.first!
        let imported = model.sessions(in: project).first!
        model.renameSession(imported, to: "My title")

        model.importSessions(
            [
                ImportedSession(
                    harnessId: "codex",
                    info: SessionInfo(
                        sessionId: "ext-1", cwd: "/tmp/a", title: "Changed agent title", updatedAt: newTimestamp)
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
        model.importSessions(
            [
                ImportedSession(
                    harnessId: "codex",
                    info: SessionInfo(sessionId: "ext-1", cwd: "/tmp/a", updatedAt: oldTimestamp)
                )
            ], serverId: "local")
        #expect(model.sessions(in: project).first?.updatedAt == refreshed.updatedAt)
    }
}
