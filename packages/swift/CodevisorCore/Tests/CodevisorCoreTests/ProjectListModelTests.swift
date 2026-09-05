import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("ProjectListModel")
struct ProjectListModelTests {
  func makeModel() -> (ProjectListModel, InMemoryStore, InMemoryStore) {
    let projectStore = InMemoryStore()
    let sessionStore = InMemoryStore()
    let model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: projectStore),
      sessionRepository: DefaultSessionRepository(store: sessionStore)
    )
    return (model, projectStore, sessionStore)
  }

  @Test("Server project locations adopt the client's machine id, not the server's")
  func projectMappingStampsClientMachineId() throws {
    // The server always reports its own id as "local"; the client must
    // re-stamp the location with the machine id it's talking to, or
    // `location(for:)` misses and isGitRepository/worktrees break on
    // remote machines.
    let server = ServerProject(
      id: UUID().uuidString,
      name: "widget",
      isArchived: false,
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
    // The git flag now resolves, so the worktree option is available.
    #expect(project.isGitRepository)
  }

  @Test("adoptServerProject registers a clone under the server's project id")
  func adoptServerProjectUsesServerId() {
    let (model, _, _) = makeModel()
    let id = UUID()
    let url = URL(fileURLWithPath: "/home/user/.codevisor/repos/widget")

    let project = model.adoptServerProject(id: id, folderURL: url, name: "widget")
    #expect(project.id == id)
    #expect(project.name == "widget")
    #expect(project.folderURL == url)
    #expect(project.locations.allSatisfy { $0.projectId == id })

    // Adopting the same project again reuses (and un-archives) the entry.
    model.archive(project)
    let again = model.adoptServerProject(id: id, folderURL: url, name: "widget")
    #expect(again.id == id)
    #expect(again.isArchived == false)
    #expect(model.projects.filter { $0.id == id }.count == 1)
  }

  @Test("Sessions created with a worktree carry the name and cwd from birth")
  func newSessionCarriesWorktree() {
    let (model, _, sessionStore) = makeModel()
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
    // Persisted, so the record survives a reload.
    let reloaded = DefaultSessionRepository(store: sessionStore).load()
    #expect(reloaded.first { $0.id == session.id }?.worktreeName == "fearless-raven")
  }

  @Test("Server refresh merges remote projects and sessions into the local cache")
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
    let model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      serverClient: fakeServer
    )

    try await waitUntil {
      model.projects.contains(project) && model.sessions.contains(scopedSession)
    }
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
    let model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      serverClient: fakeServer
    )
    try await waitUntil {
      model.sessions.first(where: { $0.id == session.id })?.latestAttentionSequence == 0
    }

    // Reproduce the production ordering: the scoped terminal event reaches
    // the visible chat before the global sidebar refresh carrying sequence
    // 1. The local cache is still 0 while the server tip is already 1.
    await fakeServer.setSessionAttention(
      id: session.id,
      latestSequence: 1,
      lastSeenSequence: 0
    )
    // The client knows of nothing unseen, so this read sends nothing at
    // all — it cannot consume the newer tip it has not rendered yet.
    #expect(model.markSessionRead(session.id, serverId: session.serverId) == nil)
    #expect(await fakeServer.snapshot().readRequests.isEmpty)

    await model.refreshFromServer()
    try await waitUntil {
      guard let updated = model.sessions.first(where: { $0.id == session.id }) else {
        return false
      }
      return updated.latestAttentionSequence == 1
        && updated.lastSeenAttentionSequence == 0
        && updated.unreadCount == 1
    }
  }

  @Test("Server refresh replaces stale local records without pushing them back")
  func serverRefreshUsesServerAuthority() async throws {
    let (model, _, _) = makeModel()
    let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/offline"))
    let session = model.newSession(in: project, title: "Offline chat", harnessId: "codex", syncToServer: false)
    model.setAgentSessionId("agent-offline", for: session.id, serverId: session.serverId)

    let fakeServer = FakeServerClient()
    model.selectServer(serverId: "local", serverClient: fakeServer)

    try await waitUntil { model.projects.isEmpty && model.sessions.isEmpty }
    let snapshot = await fakeServer.snapshot()
    #expect(!snapshot.upsertedProjectIDs.contains(project.id.uuidString))
    #expect(!snapshot.upsertedSessionIDs.contains(session.id.uuidString))
  }

  @Test("Server refresh preserves a new local session until creation is acknowledged")
  func serverRefreshPreservesPendingSession() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/pending-session"))
    let fakeServer = FakeServerClient(projects: [serverProject(from: project)])
    let model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      serverClient: fakeServer
    )
    try await waitUntil { model.projects.contains { $0.id == project.id } }

    // First-send promotion is local and immediate; the controller creates
    // the server row after agent startup, so an intervening empty snapshot
    // must not remove the selected session.
    let session = model.newSession(
      in: project,
      title: "First prompt",
      harnessId: "codex",
      syncToServer: false
    )
    await model.refreshFromServer()
    #expect(model.sessions.contains { $0.id == session.id })

    // Once the server exposes the row, the normal authoritative copy wins
    // and no duplicate optimistic record remains.
    _ = try await fakeServer.upsertSession(session)
    await model.refreshFromServer()
    #expect(model.sessions.filter { $0.id == session.id }.count == 1)
  }

  @Test("Server refresh preserves a new local project until creation is acknowledged")
  func serverRefreshPreservesPendingProject() async throws {
    let fakeServer = FakeServerClient()
    let projectUpload = Latch()
    await fakeServer.setProjectUpsertDelay { await projectUpload.wait() }
    let model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      serverClient: fakeServer
    )

    // Adding a project updates the UI immediately, while its server upload
    // remains blocked. An intervening empty snapshot must not make the
    // first-project composer fall back to project setup.
    let project = model.addProject(
      folderURL: URL(fileURLWithPath: "/tmp/pending-project")
    )
    await model.refreshFromServer()
    #expect(model.activeProjects.contains { $0.id == project.id })

    // Once the server exposes the row, the pending marker retires and the
    // normal authoritative copy replaces the optimistic one without a
    // duplicate.
    await projectUpload.open()
    await fakeServer.waitForSnapshot { snapshot in
      return snapshot.upsertedProjectIDs.contains(project.id.uuidString)
    }
    await model.refreshFromServer()
    #expect(model.projects.filter { $0.id == project.id }.count == 1)
  }

  @Test("Stale server refresh cannot revive a pending archived session")
  func serverRefreshPreservesPendingArchive() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/pending-archive"))
    let session = ChatSession(
      projectId: project.id,
      harnessId: "codex",
      title: "Archive me"
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

    // Hold the archive upload so a refresh can return the older active
    // record in between the optimistic local update and server ack.
    let archiveUpload = Latch()
    await fakeServer.setSessionUpsertDelay { await archiveUpload.wait() }
    model.archiveSession(session)
    #expect(model.sessions(in: project).isEmpty)

    await model.refreshFromServer()
    #expect(model.sessions(in: project).isEmpty)
    #expect(model.sessions.first { $0.id == session.id }?.isArchived == true)

    await archiveUpload.open()
    await fakeServer.waitForSnapshot { snapshot in
      return snapshot.upsertedSessionIDs.contains(session.id.uuidString)
    }
    await model.refreshFromServer()
    #expect(model.sessions(in: project).isEmpty)
  }

  @Test("Stale server refresh cannot resurrect an optimistically deleted project")
  func serverRefreshHonorsProjectDeleteTombstone() async throws {
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
    let model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      serverClient: fakeServer
    )
    try await waitUntil { model.sessions.contains { $0.id == session.id } }

    // Hold the server DELETE in flight so a refresh can return the older
    // snapshot that still lists the project and its chat (archiving a
    // scratch chat triggers exactly this interleaving).
    let deleteUpload = Latch()
    await fakeServer.setDeleteDelay { await deleteUpload.wait() }
    let local = try #require(model.projects.first { $0.id == project.id })
    model.removeProject(local)
    #expect(!model.projects.contains { $0.id == project.id })
    #expect(!model.sessions.contains { $0.id == session.id })

    await model.refreshFromServer()
    #expect(!model.projects.contains { $0.id == project.id })
    #expect(!model.sessions.contains { $0.id == session.id })

    // Once the DELETE lands, the next snapshot confirms the deletion and
    // the tombstone retires with it.
    await deleteUpload.open()
    await fakeServer.waitForSnapshot { snapshot in
      return snapshot.deletedProjectIDs.contains(project.id.uuidString)
    }
    await model.refreshFromServer()
    #expect(!model.projects.contains { $0.id == project.id })
    #expect(!model.sessions.contains { $0.id == session.id })
  }

  @Test("Legacy JSON metadata is uploaded exactly once before server authority takes over")
  func legacyCacheMigratesOnce() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/legacy-project"))
    let session = ChatSession(
      projectId: project.id,
      harnessId: "codex",
      agentSessionId: "legacy-agent-session",
      title: "Legacy chat"
    )
    let projectStore = InMemoryStore()
    let sessionStore = InMemoryStore()
    let migrationStore = InMemoryStore()
    DefaultProjectRepository(store: projectStore).save([project])
    DefaultSessionRepository(store: sessionStore).save([session])
    let server = FakeServerClient()
    let model = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: projectStore),
      sessionRepository: DefaultSessionRepository(store: sessionStore),
      legacyMigrationStore: migrationStore
    )

    model.selectServer(serverId: "local", serverClient: server, refresh: false)
    await model.refreshFromServer()
    var snapshot = await server.snapshot()
    #expect(snapshot.upsertedProjectIDs == [project.id.uuidString])
    #expect(snapshot.upsertedSessionIDs == [session.id.uuidString])
    #expect(migrationStore.loadData(forKey: "server-authority-v1-local") != nil)

    await model.refreshFromServer()
    snapshot = await server.snapshot()
    #expect(snapshot.upsertedProjectIDs == [project.id.uuidString])
    #expect(snapshot.upsertedSessionIDs == [session.id.uuidString])
  }
}
