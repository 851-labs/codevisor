import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("ProjectListModel fleet")
struct ProjectListModelFleetTests {
  @Test("Fleet recency ordering spans machines, most recent workspace first")
  func fleetWorkspaceRecencySorting() {
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
    let fixture = NavigationFixture()
    fixture.seed(projects: [localProject, remoteProject, remoteIdle])
    let model = fixture.projectList

    func workspace(_ project: Project, createdAt: TimeInterval) -> Workspace {
      Workspace(
        name: "Workspace",
        rootDirectory: nil,
        serverId: project.serverId,
        projectId: project.id,
        centerTree: .leaf(PaneGroupState()),
        createdAt: Date(timeIntervalSince1970: createdAt)
      )
    }

    let ordered = model.fleetActiveProjectsByWorkspaceRecency([
      workspace(localProject, createdAt: 10),
      workspace(remoteProject, createdAt: 20),
    ])
    #expect(
      ordered.map(\.name) == ["remote-work", "local-work", "remote-idle"]
    )

    let reordered = model.fleetActiveProjectsByWorkspaceRecency([
      workspace(localProject, createdAt: 10),
      workspace(remoteProject, createdAt: 20),
      workspace(localProject, createdAt: 25),
      workspace(localProject, createdAt: 15),
    ])
    #expect(
      reordered.map(\.name) == ["local-work", "remote-work", "remote-idle"]
    )
  }

  @Test("Adding a project on an explicit machine stamps, syncs, and probes")
  func addProjectOnExplicitMachine() async throws {
    let fixture = NavigationFixture()
    let model = fixture.projectList
    let client = FakeServerClient()

    let added = await model.addProject(
      folderURL: URL(fileURLWithPath: "/srv/studio-work"),
      serverId: "remote-b",
      client: client
    )

    #expect(added.serverId == "remote-b")
    #expect(model.projects.contains { $0.serverId == "remote-b" && $0.id == added.id })
    #expect(try await client.listProjects().contains { $0.id == added.id.uuidString })
    #expect(fixture.store.pendingIntents.map(\.machineId) == ["remote-b"])

    let again = await model.addProject(
      folderURL: URL(fileURLWithPath: "/srv/studio-work"),
      serverId: "remote-b",
      client: client
    )
    #expect(again.id == added.id)
    #expect(model.projects.filter { $0.serverId == "remote-b" }.count == 1)
  }

  @Test("Remote record mutations go to the record's machine")
  func remoteMutationsUseFleetClient() async throws {
    let remoteProject = Project.fromFolder(
      URL(fileURLWithPath: "/srv/studio-work"),
      serverId: "remote-b"
    )
    let remoteClient = FakeServerClient(projects: [serverProject(from: remoteProject)])
    let localClient = FakeServerClient()
    let fixture = NavigationFixture()
    fixture.connect(localClient, machineId: "local")
    fixture.connect(remoteClient, machineId: "remote-b")
    await fixture.refresh(from: remoteClient, machineId: "remote-b")
    let model = fixture.projectList
    let project = try #require(model.projects.first { $0.serverId == "remote-b" })

    let session = model.newSession(in: project, harnessId: "codex")
    #expect(fixture.store.pendingIntents.map(\.machineId) == ["remote-b"])
    await fixture.sync(with: remoteClient, machineId: "remote-b")
    #expect(await remoteClient.snapshot().upsertedSessionIDs == [session.id.uuidString])

    model.removeProject(project)
    await fixture.flush(machineId: "remote-b")
    let snapshot = await remoteClient.snapshot()
    #expect(snapshot.deletedProjectIDs == [remoteProject.id.uuidString])
    #expect(snapshot.deletedSessionIDs == [session.id.uuidString])
    let local = await localClient.snapshot()
    #expect(local.upsertedSessionIDs.isEmpty && local.deletedProjectIDs.isEmpty)
  }
}
