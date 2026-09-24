import CodevisorClient
import Foundation

@testable import CodevisorCore

/// Drives a `NavigationFixture` the way a machine connection does: records
/// reach the outbox executor once a machine is "connected", and server state
/// arrives only through snapshots fetched from a fake client.
@MainActor
extension NavigationFixture {
  /// Shows records as waiting changes -- the way previews seed data. Nothing
  /// is sent while no machine is connected.
  func seed(projects: [Project] = [], sessions: [ChatSession] = []) {
    for project in projects { store.enqueue(.upsertProject(project), machineId: project.serverId) }
    for session in sessions {
      store.enqueue(.upsertSession(session, workspaceId: nil), machineId: session.serverId)
    }
  }

  /// Makes a machine's navigation current: waiting changes for it are sent
  /// to `client` from now on.
  func connect(_ client: any CodevisorServerClienting, machineId: String = "local") {
    let client = journaled(client)
    let executor = store.executor
    let clients = executor.clientProvider
    let ready = executor.isMachineReady
    executor.clientProvider = { $0 == machineId ? client : clients($0) }
    executor.isMachineReady = { $0 == machineId || ready($0) }
    executor.resume(machineId: machineId)
  }

  /// Sends every waiting change for a machine and waits until the executor
  /// is idle again.
  func flush(machineId: String = "local") async {
    store.executor.resume(machineId: machineId)
    await store.executor.idle(machineId: machineId)
  }

  /// Fetches the machine's current state and installs it, like pull to
  /// refresh or a reconnect.
  @discardableResult
  func refresh(
    from client: any CodevisorServerClienting, machineId: String = "local"
  ) async -> ServerNavigationRefreshResult {
    await store.refresh(machineId: machineId, client: journaled(client))
  }

  /// Sends waiting changes, then shows what the server has afterwards.
  func sync(with client: any CodevisorServerClienting, machineId: String = "local") async {
    await flush(machineId: machineId)
    await refresh(from: client, machineId: machineId)
  }

  /// A fixture connected to `client`, showing its current state.
  static func connected(
    to client: any CodevisorServerClienting, machineId: String = "local"
  ) async -> NavigationFixture {
    let fixture = NavigationFixture()
    fixture.connect(client, machineId: machineId)
    await fixture.refresh(from: client, machineId: machineId)
    return fixture
  }

  func session(_ id: UUID, machineId: String = "local") -> ChatSession? {
    projectList.sessions.first { $0.serverId == machineId && $0.id == id }
  }

  /// Delivers one live navigation event carrying these records, the way a
  /// machine's event stream does.
  @discardableResult
  func applyEvent(
    machineId: String = "local", cursor: Int? = nil, projects: [Project] = [], sessions: [ChatSession] = []
  ) async -> Bool {
    let cursor = cursor ?? (store.eventCursor(for: machineId) ?? 0) + 1
    return await store.apply(
      .fixture(
        cursor: cursor, projects: projects.map(serverProject(from:)), sessions: sessions.map(serverSession(from:))),
      machineId: machineId)
  }
}

@MainActor
extension NavigationStore {
  /// `NavigationFixture.install` for a store wired by `AppEnvironment`.
  func install(
    machineId: String = "local", projects: [Project] = [], sessions: [ChatSession] = [],
    workspaces: [Workspace] = [], cursor: Int = 1
  ) async {
    for workspace in workspaces { layouts.setLayout(DeviceLayout(workspace), for: workspace.id) }
    await replace(
      .fixture(projects: projects, sessions: sessions, workspaces: workspaces, cursor: cursor),
      machineId: machineId, requestedAt: Date())
  }
}
