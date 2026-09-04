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

  @Test("Remote record mutations use the record's machine client")
  func remoteMutationsUseFleetClient() async throws {
    let store = InMemoryStore()
    let projectRepository = DefaultProjectRepository(store: store)
    let remoteProject = Project.fromFolder(
      URL(fileURLWithPath: "/srv/studio-work"),
      serverId: "remote-b"
    )
    projectRepository.save([remoteProject])
    let model = ProjectListModel(
      projectRepository: projectRepository,
      sessionRepository: DefaultSessionRepository(store: store),
      selectedServerId: "local"
    )
    let remoteClient = FakeServerClient()
    model.configureServerClientProvider { serverId in
      serverId == "remote-b" ? remoteClient : nil
    }
    let session = model.newSession(
      in: remoteProject,
      harnessId: "codex",
      syncToServer: false
    )

    model.archiveSession(session)

    try await waitUntilAsync {
      await remoteClient.snapshot().upsertedSessionIDs.contains(
        session.id.uuidString
      )
    }
    model.removeProject(remoteProject)
    try await waitUntilAsync {
      let snapshot = await remoteClient.snapshot()
      return snapshot.deletedProjectIDs.contains(remoteProject.id.uuidString)
        && snapshot.deletedSessionIDs.contains(session.id.uuidString)
    }
  }
}
