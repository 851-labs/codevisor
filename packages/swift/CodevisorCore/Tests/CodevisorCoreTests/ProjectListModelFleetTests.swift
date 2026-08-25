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
}
