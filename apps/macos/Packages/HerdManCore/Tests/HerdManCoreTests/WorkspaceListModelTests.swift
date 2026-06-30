import Foundation
import Testing
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
}
