import CodevisorClient
import Foundation

@testable import CodevisorCore

/// The navigation stack wired the way `AppEnvironment` wires it, over an
/// in-memory store: a `NavigationStore` and the models that render it.
///
/// Tests put server state in place with `install`, which does what a
/// machine's snapshot does. They never assign `projectList.sessions` or save
/// server fields through the repository -- the app can't either.
@MainActor
final class NavigationFixture {
  let persistence: InMemoryStore
  let store: NavigationStore
  let projectList: ProjectListModel
  let workspaces: ProjectedWorkspaceRepository
  let workspaceSync: WorkspaceSyncModel

  init(
    persistence: InMemoryStore = InMemoryStore(),
    clock: any Clock<Duration> = ContinuousClock(),
    now: @escaping () -> Date = Date.init
  ) {
    self.persistence = persistence
    store = NavigationStore(store: persistence, clock: clock, now: now)
    projectList = ProjectListModel()
    projectList.navigationStore = store
    workspaces = ProjectedWorkspaceRepository(store: store)
    workspaceSync = WorkspaceSyncModel(repository: workspaces, projectList: projectList)
    workspaceSync.navigationStore = store
    store.attach(projectList: projectList, repository: workspaces)
  }

  /// Installs a machine's snapshot built from app records. A workspace's
  /// chat panes assign those chats to it, its panes become server panes, and
  /// its tab arrangement becomes this device's layout.
  func install(
    machineId: String = "local",
    projects: [Project] = [],
    sessions: [ChatSession] = [],
    workspaces: [Workspace] = [],
    cursor: Int = 1
  ) async {
    for workspace in workspaces {
      store.layouts.setLayout(DeviceLayout(workspace), for: workspace.id)
    }
    await store.replace(
      .fixture(projects: projects, sessions: sessions, workspaces: workspaces, cursor: cursor),
      machineId: machineId, requestedAt: Date())
  }
}

extension ServerNavigationSnapshot {
  static func fixture(
    projects: [Project] = [],
    sessions: [ChatSession] = [],
    workspaces: [Workspace] = [],
    cursor: Int = 1
  ) -> ServerNavigationSnapshot {
    var assignments: [UUID: UUID] = [:]
    for workspace in workspaces {
      for sessionId in workspace.chatSessionIds { assignments[sessionId] = workspace.id }
    }
    return ServerNavigationSnapshot(
      eventCursor: cursor,
      projects: projects.map(serverProject(from:)),
      sessions: sessions.map { session in
        var record = serverSession(from: session)
        record.workspaceId = assignments[session.id]?.uuidString
        return record
      },
      workspaces: workspaces.map(WorkspaceSyncModel.serverWorkspace(from:)),
      panes: workspaces.flatMap { workspace in
        WorkspaceSyncModel.allPanes(in: workspace).compactMap { pane in
          pane.kind == .newTab
            ? nil : WorkspaceSyncModel.serverPane(from: pane, workspaceId: workspace.id, createdAt: workspace.createdAt)
        }
      })
  }
}

extension ProjectListModel {
  /// A project list rendering its own navigation store, for tests that only
  /// need one to hand to another component.
  @MainActor
  static func fixture() -> ProjectListModel { NavigationFixture().projectList }
}
