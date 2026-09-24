import Foundation
import Testing
import CodevisorTestSupport
import ACPKit
@testable import CodevisorCore

@MainActor
extension ProjectListModelTests {
  @Test("A machine's refresh is filed under that machine and leaves others alone")
  func serverRefreshScopesToMachine() async throws {
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
    let fixture = NavigationFixture()
    await fixture.install(projects: [localProject])
    let remoteServer = FakeServerClient(
      projects: [serverProject(from: remoteProject)],
      sessions: [serverSession(from: remoteSession)]
    )

    await fixture.refresh(from: remoteServer, machineId: "remote-mac-mini")

    let model = fixture.projectList
    #expect(model.projects.contains { $0.id == localProject.id && $0.serverId == "local" })
    #expect(model.projects.contains { $0.id == remoteProject.id && $0.serverId == "remote-mac-mini" })
    #expect(model.sessions.contains { $0.id == remoteSession.id && $0.serverId == "remote-mac-mini" })
    // The selected machine's sidebar shows only its own projects.
    #expect(model.activeProjects.map(\.id) == [localProject.id])
  }

  @Test("Identical project and session ids stay isolated between machines")
  func duplicateIdsStayMachineScoped() async throws {
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
    let fixture = NavigationFixture()
    await fixture.install(machineId: "local", projects: [localProject], sessions: [localSession])
    await fixture.install(machineId: "remote-a", projects: [remoteProject], sessions: [remoteSession])
    let model = fixture.projectList

    var renamedRemote = remoteProject
    renamedRemote.name = "Renamed remote project"
    let fake = FakeServerClient(
      projects: [serverProject(from: renamedRemote)], sessions: [serverSession(from: remoteSession)])
    fixture.connect(fake, machineId: "remote-a")
    model.renameSession(remoteSession, to: "Renamed remote")
    await fixture.sync(with: fake, machineId: "remote-a")

    // A write scoped to one machine never rewrites the other's record.
    #expect(model.projects.first { $0.serverId == "local" }?.name == localProject.name)
    #expect(model.projects.first { $0.serverId == "remote-a" }?.name == "Renamed remote project")
    #expect(model.sessions.first { $0.serverId == "local" }?.title == "Local chat")
    #expect(model.sessions.first { $0.serverId == "remote-a" }?.title == "Renamed remote")

    model.removeProject(try #require(model.projects.first { $0.serverId == "remote-a" }))
    #expect(model.projects.contains { $0.serverId == "local" && $0.id == projectId })
    #expect(model.sessions.contains { $0.serverId == "local" && $0.id == sessionId })
    #expect(!model.projects.contains { $0.serverId == "remote-a" && $0.id == projectId })
    #expect(!model.sessions.contains { $0.serverId == "remote-a" && $0.id == sessionId })
  }

  @Test("A slow refresh from one machine is never filed under another")
  func slowRefreshStaysOnItsMachine() async throws {
    let remoteProject = Project.fromFolder(
      URL(fileURLWithPath: "/srv/remote-only"),
      createdAt: Date(timeIntervalSince1970: 5)
    )
    let fixture = NavigationFixture()
    let latch = Latch()
    let remoteServer = FakeServerClient(projects: [serverProject(from: remoteProject)])
    let listStarted = TestSignal()
    await remoteServer.setListDelay {
      listStarted.signal(); await latch.wait()
    }

    // Start a refresh against the remote machine, and refresh local while
    // its list call is still in flight (a slow network hop).
    let refresh = Task { _ = await fixture.refresh(from: remoteServer, machineId: "remote-mac-mini") }
    await listStarted.wait()
    await fixture.refresh(from: FakeServerClient(), machineId: "local")
    await latch.open()
    await refresh.value

    // The remote response must never be filed under "local" — that would
    // put another machine's projects in the local sidebar forever.
    let model = fixture.projectList
    #expect(!model.projects.contains { $0.id == remoteProject.id && $0.serverId == "local" })
    #expect(model.projects.contains { $0.id == remoteProject.id && $0.serverId == "remote-mac-mini" })
    #expect(model.activeProjects.isEmpty)
  }

  @Test("Imports are filed under the machine they were discovered on, not the current selection")
  func importTagsDiscoveryServer() {
    // Discovery ran against the remote machine, but local is selected: the
    // results still belong to the remote machine.
    let model = NavigationFixture().projectList
    model.showsImportedSessions = true
    model.importSessions(
      [
        ImportedSession(
          harnessId: "codex", info: SessionInfo(sessionId: "r-1", cwd: "/srv/proj", title: "Remote"))
      ], serverId: "remote-mac-mini")

    #expect(!model.projects.isEmpty)
    #expect(model.projects.allSatisfy { $0.serverId == "remote-mac-mini" })
    #expect(model.sessions.allSatisfy { $0.serverId == "remote-mac-mini" })
    // Nothing leaks into the (selected) local sidebar.
    #expect(model.activeProjects.isEmpty)
  }

  @Test("Sessions imported into a project inherit the project's machine")
  func importIntoProjectInheritsProjectServer() {
    let model = NavigationFixture().projectList
    model.showsImportedSessions = true
    // The project lives on the remote machine; local is selected.
    let project = model.addProject(folderURL: URL(fileURLWithPath: "/srv/proj"), serverId: "remote-mac-mini")

    // Confirming a pending import must not re-tag the sessions to the
    // selected machine.
    model.importSessions(
      [
        ImportedSession(
          harnessId: "codex", info: SessionInfo(sessionId: "r-2", cwd: "/srv/proj", title: "Remote"))
      ], into: project)

    #expect(model.sessions.count == 1)
    #expect(model.sessions.allSatisfy { $0.serverId == "remote-mac-mini" })
    #expect(model.activeProjects.isEmpty)
  }
}
