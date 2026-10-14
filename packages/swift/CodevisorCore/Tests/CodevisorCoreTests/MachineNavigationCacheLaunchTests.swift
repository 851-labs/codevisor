import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineNavigationCacheLaunchTests {
  @Test("A machine with a cache on disk starts cached, its workspaces visible before any network")
  func cachedMachineShowsWorkspacesOffline() async throws {
    let launch = await CachedLaunch.make()
    let fake = launch.serverClient()
    let controller = MachineController(
      store: InMemoryStore(), projectList: launch.fixture.projectList, clientFactory: { _ in fake })
    defer { controller.stopEventSync() }

    #expect(launch.fixture.store.hasCache(for: "local"))
    #expect(controller.navigationSyncStateByMachineId["local"] == .cached)
    let workspace = try #require(launch.fixture.workspaces.workspace(id: launch.workspace.id))
    #expect(workspace.name == "Launch workspace")
    #expect(workspace.chatSessionIds == [launch.session.id])
    #expect(launch.fixture.projectList.sessions.map(\.id) == [launch.session.id])
    #expect(launch.fixture.projectList.projects.map(\.id) == [launch.project.id])
    #expect(fake.workspaceSnapshotCallCount == 0)
    #expect(fake.listSessionCallCount == 0)
  }

  @Test("A full sync moves a cached machine to current and sends the changes made meanwhile")
  func fullSyncResumesOutbox() async throws {
    let launch = await CachedLaunch.make()
    let fake = launch.serverClient()
    let controller = MachineController(
      store: InMemoryStore(), projectList: launch.fixture.projectList, clientFactory: { _ in fake })
    defer { controller.stopEventSync() }
    let store = launch.fixture.store

    store.enqueue(
      .renameWorkspace(workspaceId: launch.workspace.id, name: "Renamed offline", hasCustomName: true),
      machineId: "local")
    await store.executor.idle(machineId: "local")
    #expect(fake.workspaceRenameNames.isEmpty)
    #expect(store.pendingIntents.map(\.state) == [.pending])
    #expect(launch.fixture.workspaces.workspace(id: launch.workspace.id)?.name == "Renamed offline")

    await controller.refreshNavigationState(for: "local")
    #expect(controller.navigationSyncStateByMachineId["local"] == .current)
    await store.executor.idle(machineId: "local")

    #expect(fake.workspaceRenameNames == ["Renamed offline"])
    #expect(!store.pendingIntents.contains { $0.state == .pending })
    #expect(fake.workspaces.first?.name == "Renamed offline")
  }
}

@MainActor
private struct CachedLaunch {
  let fixture: NavigationFixture
  let project: Project
  let session: ChatSession
  let workspace: Workspace
  let snapshot: ServerNavigationSnapshot

  static func make() async -> CachedLaunch {
    let persistence = InMemoryStore()
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/cached-launch"))
    let session = ChatSession(projectId: project.id, serverId: "local", title: "Cached chat")
    let workspace = Workspace(
      name: "Launch workspace", rootDirectory: "/tmp/cached-launch", serverId: "local",
      projectId: project.id, centerTree: .leaf(.centerInitial(sessionId: session.id)), isServerSynced: true)
    let snapshot = ServerNavigationSnapshot.fixture(
      projects: [project], sessions: [session], workspaces: [workspace], cursor: 0)

    let previous = NavigationFixture(persistence: persistence)
    await previous.install(projects: [project], sessions: [session], workspaces: [workspace], cursor: 0)
    PersistenceEncoding.drain()

    return CachedLaunch(
      fixture: NavigationFixture(persistence: persistence), project: project, session: session,
      workspace: workspace, snapshot: snapshot)
  }

  func serverClient() -> SyncFakeServerClient {
    SyncFakeServerClient(
      projects: snapshot.projects, sessions: snapshot.sessions, workspaces: snapshot.workspaces,
      panes: snapshot.panes)
  }
}
