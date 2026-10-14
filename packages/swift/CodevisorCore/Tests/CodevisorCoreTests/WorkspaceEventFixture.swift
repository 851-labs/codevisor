import ACPKit
import CodevisorTestSupport
import Foundation

@testable import CodevisorCore

@MainActor
final class WorkspaceEventFixture {
  let serverId = "local"
  let anchorSessionId = UUID()
  let navigation: NavigationFixture
  let fake: SyncFakeServerClient
  let controller: MachineController
  let workspace: Workspace
  let otherWorkspace: Workspace

  var repository: ProjectedWorkspaceRepository { navigation.workspaces }
  var sync: WorkspaceSyncModel { navigation.workspaceSync }
  var projectList: ProjectListModel { navigation.projectList }
  var store: NavigationStore { navigation.store }

  init(navigationClock: any Clock<Duration> = ContinuousClock(), cachesWorkspace: Bool = true) async {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let project = Project(serverId: "local", name: "Shared", createdAt: createdAt)
    workspace = Workspace(
      name: "Shared", rootDirectory: "/tmp/shared", serverId: "local", projectId: project.id,
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: anchorSessionId, paneId: anchorSessionId)))],
      createdAt: createdAt, isServerSynced: true)
    otherWorkspace = Workspace(
      name: "Other machine", rootDirectory: nil, serverId: "another-mac", projectId: UUID(),
      centerTabs: [.placeholder()], createdAt: createdAt, isServerSynced: true)
    let session = ChatSession(id: anchorSessionId, projectId: project.id, serverId: "local", createdAt: createdAt)
    navigation = NavigationFixture()
    let snapshot = ServerNavigationSnapshot.fixture(projects: [project], sessions: [session], workspaces: [workspace])
    fake = SyncFakeServerClient(
      projects: snapshot.projects, sessions: snapshot.sessions, workspaces: snapshot.workspaces,
      panes: snapshot.panes)
    let client = fake
    controller = MachineController(
      store: InMemoryStore(), projectList: navigation.projectList, workspaceSync: navigation.workspaceSync,
      clientFactory: { _ in client }, navigationClock: navigationClock)
    await navigation.install(
      machineId: "local", projects: [project], sessions: [session],
      workspaces: cachesWorkspace ? [workspace] : [], cursor: 0)
    await navigation.install(machineId: "another-mac", workspaces: [otherWorkspace], cursor: 0)
  }

  var routeDisposition: WorkspaceRouteDisposition {
    sync.routeDisposition(
      workspaceId: workspace.id, anchorSessionId: anchorSessionId, serverId: serverId,
      preservingSelectedPane: true)
  }

  func payload(isArchived: Bool, name: String) -> JSONValue {
    var record = WorkspaceSyncModel.serverWorkspace(from: workspace)
    record.name = name
    record.hasCustomName = name != workspace.name
    record.isArchived = isArchived
    return navigationFixtureJSON(record)
  }

  func archivedSnapshot() -> FakeWorkspaceSnapshot {
    var record = WorkspaceSyncModel.serverWorkspace(from: workspace)
    record.isArchived = true
    return FakeWorkspaceSnapshot(workspaces: [record], panes: fake.workspacePanes ?? [])
  }

  func stop() async {
    let connection = controller.connection(for: serverId)
    let tasks = [
      connection.eventSyncTask, connection.navigationRetryTask, connection.navigationSyncTask,
      connection.pendingRefreshTask,
    ].compactMap { $0 }
    controller.stopEventSync()
    for task in tasks { await task.value }
  }
}
