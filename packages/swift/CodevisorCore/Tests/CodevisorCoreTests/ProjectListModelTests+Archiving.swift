import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
extension ProjectListModelTests {
    @Test("Unarchiving a chat survives the next server refresh")
    func unarchiveClearsPendingArchiveMarker() async throws {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/unarchive"))
        let session = ChatSession(
            projectId: project.id,
            harnessId: "codex",
            title: "Restore me"
        )
        let fakeServer = FakeServerClient(
            projects: [serverProject(from: project)],
            sessions: [serverSession(from: session)]
        )
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )
        try await waitUntil { model.sessions.contains { $0.id == session.id } }

        model.archiveSession(session)
        #expect(model.sessions(in: project).isEmpty)
        #expect(model.archivedSessions(in: project).count == 1)

        model.unarchiveSession(session)
        #expect(model.sessions(in: project).count == 1)
        #expect(model.archivedSessions(in: project).isEmpty)

        // The regression this guards: the optimistic archive marker forces
        // `isArchived = true` onto any matching remote row, so an unarchive
        // that left the marker behind would silently re-archive the chat on
        // the very next refresh.
        await model.refreshFromServer()
        #expect(model.sessions(in: project).count == 1)
        #expect(model.sessions.first { $0.id == session.id }?.isArchived == false)
    }

    @Test("A freshly archived chat sorts to the top of the archived list")
    func archivedSessionsOrderByArchiveTime() async throws {
        let project = Project(id: UUID(), serverId: "local", name: "Order")
        // `recentlyActive` is the newer chat by conversation activity, so an
        // ordering keyed on updatedAt would wrongly float it above the chat
        // the user just archived.
        let recentlyActive = ChatSession(
            projectId: project.id,
            serverId: "local",
            harnessId: "codex",
            title: "Recently active",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 9_000)
        )
        let stale = ChatSession(
            projectId: project.id,
            serverId: "local",
            harnessId: "codex",
            title: "Stale",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let projectStore = InMemoryStore()
        let sessionStore = InMemoryStore()
        DefaultProjectRepository(store: projectStore).save([project])
        DefaultSessionRepository(store: sessionStore).save([recentlyActive, stale])
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: projectStore),
            sessionRepository: DefaultSessionRepository(store: sessionStore)
        )

        model.archiveSession(recentlyActive)
        model.archiveSession(stale)

        // `stale` was archived last, so it leads regardless of its older
        // conversation activity.
        #expect(model.archivedSessions.map(\.title) == ["Stale", "Recently active"])
        #expect(model.archivedSessions.first?.archivedAt != nil)
        #expect(model.archivedSessions(in: project).map(\.title) == ["Stale", "Recently active"])

        // Restoring clears the stamp so a later re-archive re-sorts correctly.
        model.unarchiveSession(stale)
        #expect(model.sessions.first { $0.id == stale.id }?.archivedAt == nil)
        #expect(model.archivedSessions.map(\.title) == ["Recently active"])
    }

    @Test("Archived chats stay listed once their project has no active chats left")
    func archivedSessionsSurviveEmptyImportedProject() async throws {
        // An imported project leaves `activeProjects` as soon as its last
        // active chat is archived; the archive must not vanish with it.
        let project = Project(id: UUID(), serverId: "local", name: "Imported", origin: .imported)
        let session = ChatSession(
            projectId: project.id,
            serverId: "local",
            harnessId: "codex",
            title: "Only chat",
            origin: .imported
        )
        let projectStore = InMemoryStore()
        let sessionStore = InMemoryStore()
        DefaultProjectRepository(store: projectStore).save([project])
        DefaultSessionRepository(store: sessionStore).save([session])
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: projectStore),
            sessionRepository: DefaultSessionRepository(store: sessionStore)
        )

        model.archiveSession(session)

        #expect(model.activeProjects.isEmpty)
        #expect(model.archivedSessions.map(\.title) == ["Only chat"])
    }
}
