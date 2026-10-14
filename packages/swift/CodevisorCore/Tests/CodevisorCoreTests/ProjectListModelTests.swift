import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("ProjectListModel")
struct ProjectListModelTests {
  @Test("Server project locations adopt the client's machine id, not the server's")
  func projectMappingStampsClientMachineId() throws {
    let server = ServerProject(
      id: UUID().uuidString,
      name: "widget",
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
    #expect(project.isGitRepository)
  }

  @Test("adoptServerProject registers a clone under the server's project id")
  func adoptServerProjectUsesServerId() {
    let model = NavigationFixture().projectList
    let id = UUID()
    let url = URL(fileURLWithPath: "/home/user/.codevisor/repos/widget")

    let project = model.adoptServerProject(id: id, folderURL: url, name: "widget")
    #expect(project.id == id)
    #expect(project.name == "widget")
    #expect(project.folderURL == url)
    #expect(project.locations.allSatisfy { $0.projectId == id })

    let again = model.adoptServerProject(id: id, folderURL: url, name: "widget")
    #expect(again.id == id)
    #expect(model.projects.filter { $0.id == id }.count == 1)
  }

  @Test("Sessions created with a worktree carry the name and cwd from birth")
  func newSessionCarriesWorktree() {
    let persistence = InMemoryStore()
    let model = NavigationFixture(persistence: persistence).projectList
    let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/repo"))
    let session = model.newSession(
      in: project,
      title: "Draft",
      harnessId: "codex",
      worktreeName: "fearless-raven",
      cwd: "/tmp/worktrees/fearless-raven",
      syncToServer: false
    )

    let created = model.sessions.first { $0.id == session.id }
    #expect(created?.worktreeName == "fearless-raven")
    #expect(created?.cwd == "/tmp/worktrees/fearless-raven")
    PersistenceEncoding.drain()
    let relaunched = NavigationFixture(persistence: persistence).projectList
    #expect(relaunched.sessions.first { $0.id == session.id }?.worktreeName == "fearless-raven")
  }

  @Test("Server refresh brings in remote projects and sessions, scoped to the machine")
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
      createdAt: Date(timeIntervalSince1970: 11),
      sidebarState: .inProgress,
      sidebarStateChangedAt: Date(timeIntervalSince1970: 12)
    )
    let scopedSession = ChatSession(
      id: remoteSession.id,
      projectId: project.id,
      serverId: "local",
      harnessId: remoteSession.harnessId,
      agentSessionId: remoteSession.agentSessionId,
      title: remoteSession.title,
      createdAt: remoteSession.createdAt,
      sidebarState: remoteSession.sidebarState,
      sidebarStateChangedAt: remoteSession.sidebarStateChangedAt
    )
    let fakeServer = FakeServerClient(
      projects: [serverProject(from: project)],
      sessions: [serverSession(from: remoteSession)]
    )
    let model = await NavigationFixture.connected(to: fakeServer).projectList

    #expect(model.projects.contains(project))
    #expect(model.sessions.contains(scopedSession))
  }

  @Test("Delayed visible-session read cannot consume a newer server tip")
  func delayedVisibleSessionReadPreservesNewerTip() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/visible-read"))
    let session = ChatSession(
      id: UUID(),
      projectId: project.id,
      harnessId: "codex",
      title: "Visible"
    )
    let fakeServer = FakeServerClient(
      projects: [serverProject(from: project)],
      sessions: [serverSession(from: session)]
    )
    let fixture = await NavigationFixture.connected(to: fakeServer)
    let model = fixture.projectList
    #expect(fixture.session(session.id)?.latestAttentionSequence == 0)

    await fakeServer.setSessionAttention(
      id: session.id,
      latestSequence: 1,
      lastSeenSequence: 0
    )
    #expect(model.markSessionRead(session.id, serverId: session.serverId) == nil)
    #expect(fixture.store.pendingIntents.isEmpty)
    await fixture.flush()
    #expect(await fakeServer.snapshot().readRequests.isEmpty)

    await fixture.refresh(from: fakeServer)
    let updated = try #require(fixture.session(session.id))
    #expect(updated.latestAttentionSequence == 1)
    #expect(updated.lastSeenAttentionSequence == 0)
    #expect(updated.unreadCount == 1)
  }

  @Test("Server refresh replaces a stale cache without pushing it back")
  func serverRefreshUsesServerAuthority() async throws {
    let fixture = NavigationFixture()
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/offline"))
    let session = ChatSession(
      projectId: project.id, harnessId: "codex", agentSessionId: "agent-offline", title: "Offline chat")
    await fixture.install(projects: [project], sessions: [session])
    #expect(fixture.projectList.projects.map(\.id) == [project.id])

    let fakeServer = FakeServerClient()
    fixture.connect(fakeServer)
    await fixture.refresh(from: fakeServer)
    await fixture.flush()

    #expect(fixture.projectList.projects.isEmpty)
    #expect(fixture.projectList.sessions.isEmpty)
    let snapshot = await fakeServer.snapshot()
    #expect(snapshot.upsertedProjectIDs.isEmpty)
    #expect(snapshot.upsertedSessionIDs.isEmpty)
  }

  @Test("Server refresh keeps showing a new local session until the server lists it")
  func serverRefreshPreservesPendingSession() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/pending-session"))
    let fakeServer = FakeServerClient(projects: [serverProject(from: project)])
    let fixture = await NavigationFixture.connected(to: fakeServer)
    let model = fixture.projectList
    #expect(model.projects.contains { $0.id == project.id })

    let session = model.newSession(
      in: project,
      title: "First prompt",
      harnessId: "codex",
      syncToServer: false
    )
    await fixture.refresh(from: fakeServer)
    await fixture.flush()
    #expect(model.sessions.contains { $0.id == session.id })
    #expect(await fakeServer.snapshot().upsertedSessionIDs.isEmpty)

    _ = try await fakeServer.upsertSession(session)
    await fixture.refresh(from: fakeServer)
    #expect(model.sessions.filter { $0.id == session.id }.count == 1)
    #expect(fixture.store.pendingIntents.isEmpty)
  }

  @Test("Server refresh keeps showing a new local project until the server has it")
  func serverRefreshPreservesPendingProject() async throws {
    let fakeServer = FakeServerClient()
    let projectUpload = Latch()
    await fakeServer.setProjectUpsertDelay { await projectUpload.wait() }
    let fixture = await NavigationFixture.connected(to: fakeServer)
    let model = fixture.projectList

    let project = model.addProject(
      folderURL: URL(fileURLWithPath: "/tmp/pending-project")
    )
    await fixture.refresh(from: fakeServer)
    #expect(model.fleetActiveProjects.contains { $0.id == project.id })

    await projectUpload.open()
    await fixture.flush()
    #expect(await fakeServer.snapshot().upsertedProjectIDs == [project.id.uuidString])
    await fixture.refresh(from: fakeServer)
    #expect(model.projects.filter { $0.id == project.id }.count == 1)
    #expect(fixture.store.pendingIntents.isEmpty)
  }

  @Test("Stale server refresh cannot resurrect a project being deleted")
  func serverRefreshHonorsProjectDelete() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/one-time-chat"))
    let session = ChatSession(
      projectId: project.id,
      harnessId: "codex",
      title: "One-time chat"
    )
    let fakeServer = FakeServerClient(
      projects: [serverProject(from: project)],
      sessions: [serverSession(from: session)]
    )
    let fixture = await NavigationFixture.connected(to: fakeServer)
    let model = fixture.projectList
    #expect(model.sessions.contains { $0.id == session.id })

    let deleteUpload = Latch()
    await fakeServer.setDeleteDelay { await deleteUpload.wait() }
    let local = try #require(model.projects.first { $0.id == project.id })
    model.removeProject(local)
    #expect(!model.projects.contains { $0.id == project.id })
    #expect(!model.sessions.contains { $0.id == session.id })
    #expect(model.isProjectDeleted(id: project.id, serverId: project.serverId))

    await fixture.refresh(from: fakeServer)
    #expect(!model.projects.contains { $0.id == project.id })
    #expect(!model.sessions.contains { $0.id == session.id })

    await deleteUpload.open()
    await fixture.flush()
    let snapshot = await fakeServer.snapshot()
    #expect(snapshot.deletedSessionIDs == [session.id.uuidString])
    #expect(snapshot.deletedProjectIDs == [project.id.uuidString])
    await fixture.refresh(from: fakeServer)
    #expect(!model.projects.contains { $0.id == project.id })
    #expect(!model.sessions.contains { $0.id == session.id })
    #expect(fixture.store.pendingIntents.isEmpty)
  }
}
