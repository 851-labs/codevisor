import Foundation
import Testing

@testable import CodevisorCore

/// Fleet-wide project ordering for the composer's machine-spanning picker.
@MainActor
@Suite("ProjectListModel fleet")
struct ProjectListModelFleetTests {
    @Test("Fleet recency ordering spans machines, most recent workspace first")
    func fleetWorkspaceRecencySorting() {
        let store = InMemoryStore()
        let repository = DefaultProjectRepository(store: store)
        let localProject = Project.fromFolder(
            URL(fileURLWithPath: "/tmp/local-work"),
            createdAt: Date(timeIntervalSince1970: 5)
        )
        let remoteProject = Project.fromFolder(
            URL(fileURLWithPath: "/srv/remote-work"),
            serverId: "remote-b",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let remoteIdle = Project.fromFolder(
            URL(fileURLWithPath: "/srv/remote-idle"),
            serverId: "remote-b",
            createdAt: Date(timeIntervalSince1970: 9)
        )
        repository.save([localProject, remoteProject, remoteIdle])
        let model = ProjectListModel(
            projectRepository: repository,
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )

        func workspace(_ project: Project, createdAt: TimeInterval) -> Workspace {
            Workspace(
                name: "Workspace",
                rootDirectory: nil,
                serverId: project.serverId,
                projectId: project.id,
                centerTree: .leaf(PaneGroupState()),
                bottomGroup: PaneGroupState(),
                createdAt: Date(timeIntervalSince1970: createdAt)
            )
        }

        // The remote machine's workspace history counts even though "local"
        // is the selected machine — the picker is the fleet's.
        let ordered = model.fleetActiveProjectsByWorkspaceRecency([
            workspace(localProject, createdAt: 10),
            workspace(remoteProject, createdAt: 20),
        ])
        #expect(
            ordered.map(\.name) == ["remote-work", "local-work", "remote-idle"]
        )
    }

    @Test("Initial project selection stays on its machine and skips scratch projects")
    func initialProjectSelection() {
        let repository = DefaultProjectRepository(store: InMemoryStore())
        let otherMachine = Project.fromFolder(
            URL(fileURLWithPath: "/srv/other"),
            serverId: "remote-a"
        )
        let scratch = Project(
            serverId: "remote-b",
            name: "scratch",
            createdAt: Date(timeIntervalSince1970: 30),
            isScratch: true
        )
        let expected = Project.fromFolder(
            URL(fileURLWithPath: "/srv/project"),
            serverId: "remote-b",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        repository.save([otherMachine, scratch, expected])
        let model = ProjectListModel(
            projectRepository: repository,
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )

        #expect(
            model.firstNonScratchProject(on: "remote-b", byWorkspaceRecency: []) == expected
        )
        #expect(model.firstNonScratchProject(on: "fresh-vnc", byWorkspaceRecency: []) == nil)
    }

    @Test("Adding a project on an explicit machine stamps, syncs, and probes")
    func addProjectOnExplicitMachine() async throws {
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let client = FakeServerClient()

        let added = await model.addProject(
            folderURL: URL(fileURLWithPath: "/srv/studio-work"),
            serverId: "remote-b",
            client: client
        )

        // Stamped with the PICKED machine, not the selected one; the awaited
        // upsert reached the picked machine's client.
        #expect(added.serverId == "remote-b")
        #expect(model.projects.contains { $0.serverId == "remote-b" && $0.id == added.id })
        #expect(try await client.listProjects().contains { $0.id == added.id.uuidString })

        // Re-adding the same folder on the same machine reuses the record.
        let again = await model.addProject(
            folderURL: URL(fileURLWithPath: "/srv/studio-work"),
            serverId: "remote-b",
            client: client
        )
        #expect(again.id == added.id)
        #expect(model.projects.filter { $0.serverId == "remote-b" }.count == 1)
    }
}
