import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
extension ProjectListModelTests {
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
        model.importSessions(
            [
                ImportedSession(
                    harnessId: "codex", info: SessionInfo(sessionId: "r-1", cwd: "/srv/proj", title: "Remote"))
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
        model.importSessions(
            [
                ImportedSession(
                    harnessId: "codex", info: SessionInfo(sessionId: "r-2", cwd: "/srv/proj", title: "Remote"))
            ], into: project)

        #expect(model.sessions.allSatisfy { $0.serverId == "remote-mac-mini" })
        #expect(model.activeProjects.isEmpty)
    }
}
