import ACPKit
import CodevisorTestSupport
import Foundation

@testable import CodevisorClient
@testable import CodevisorCore

extension ServerNavigationDelta {
  /// A `navigation.changed` payload, exactly as a machine's journal emits it.
  static func fixture(
    cursor: Int,
    projects: [ServerProject] = [],
    sessions: [ServerSession] = [],
    workspaces: [ServerWorkspace] = [],
    panes: [ServerWorkspacePane] = [],
    deleted: [(table: String, id: String)] = []
  ) -> ServerNavigationDelta {
    ServerNavigationDelta(
      eventCursor: cursor, projects: projects, sessions: sessions, workspaces: workspaces, panes: panes,
      deleted: deleted.map { Deletion(table: $0.table, id: $0.id) })
  }
}

/// A machine's navigation database and journal, reduced to what the outbox
/// sends. Every accepted change moves the state forward and records one
/// event, so `latestShellEventCursor` after a request always covers it --
/// like the real server. Events reach the device only when a test calls
/// `deliver`, which is what lets tests hold the window between a request
/// being accepted and its event arriving.
final class NavigationJournalServer: CodevisorServerClienting, @unchecked Sendable {
  private let lock = NSLock()
  private var state: ServerNavigationSnapshot
  private var undelivered: [ServerNavigationDelta] = []
  private var log: [String] = []
  private var requestHook: (@Sendable (String) async throws -> Void)?
  private var snapshotHook: (@Sendable () async -> Void)?

  init(_ snapshot: ServerNavigationSnapshot) {
    state = snapshot
  }

  /// Every request the outbox made, in order (`rename:<name>`, `reorder:<revision>`, ...).
  var requests: [String] { lock.withLock { log } }
  var current: ServerNavigationSnapshot { lock.withLock { state } }
  var pendingEventCount: Int { lock.withLock { undelivered.count } }

  func workspace(_ id: UUID) -> ServerWorkspace? {
    current.workspaces.first { UUID(uuidString: $0.id) == id }
  }

  func panes(in workspaceId: UUID) -> [ServerWorkspacePane] {
    current.panes.filter { UUID(uuidString: $0.workspaceId) == workspaceId }
  }

  /// Runs before each request is applied; a test can hold it or make it fail.
  func onRequest(_ hook: (@Sendable (String) async throws -> Void)?) {
    lock.withLock { requestHook = hook }
  }

  /// Runs after a snapshot's contents are read but before it is returned,
  /// so a test can hold a refresh in flight while newer events land.
  func onSnapshot(_ hook: (@Sendable () async -> Void)?) {
    lock.withLock { snapshotHook = hook }
  }

  /// Commits a change made on the server (or by another device).
  @discardableResult
  func commit(
    sessions: [ServerSession] = [],
    workspaces: [ServerWorkspace] = [],
    panes: [ServerWorkspacePane] = [],
    deleted: [(table: String, id: String)] = []
  ) -> Int {
    lock.withLock { commitLocked(sessions: sessions, workspaces: workspaces, panes: panes, deleted: deleted) }
  }

  /// Delivers every event the device hasn't received yet, in order.
  func deliver(to store: NavigationStore, machineId: String) async {
    let deltas = lock.withLock {
      defer { undelivered.removeAll() }
      return undelivered
    }
    for delta in deltas { _ = await store.apply(delta, machineId: machineId) }
  }

  /// Delivers only the oldest undelivered event.
  func deliverNext(to store: NavigationStore, machineId: String) async {
    let delta: ServerNavigationDelta? = lock.withLock {
      undelivered.isEmpty ? nil : undelivered.removeFirst()
    }
    if let delta { _ = await store.apply(delta, machineId: machineId) }
  }

  private func commitLocked(
    sessions: [ServerSession] = [],
    workspaces: [ServerWorkspace] = [],
    panes: [ServerWorkspacePane] = [],
    deleted: [(table: String, id: String)] = []
  ) -> Int {
    let delta = ServerNavigationDelta.fixture(
      cursor: state.eventCursor + 1, sessions: sessions, workspaces: workspaces, panes: panes, deleted: deleted)
    state = delta.applying(to: state)
    undelivered.append(delta)
    return delta.eventCursor
  }

  private func request(_ name: String) async throws {
    let hook = lock.withLock {
      log.append(name)
      return requestHook
    }
    try await hook?(name)
  }

  private func updateWorkspace(_ id: UUID, _ change: (inout ServerWorkspace) -> Bool) throws -> ServerWorkspace {
    try lock.withLock {
      guard var record = state.workspaces.first(where: { UUID(uuidString: $0.id) == id }) else {
        throw CodevisorServerClientError.httpStatus(404, "Missing workspace")
      }
      if change(&record) { _ = commitLocked(workspaces: [record]) }
      return record
    }
  }

  // MARK: - Navigation requests

  func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    let (snapshot, hook) = lock.withLock { (state, snapshotHook) }
    await hook?()
    return snapshot
  }

  func latestShellEventCursor() async throws -> Int { current.eventCursor }

  func renameWorkspace(id: UUID, name: String, hasCustomName: Bool) async throws {
    try await request("rename:\(name)")
    _ = try updateWorkspace(id) { record in
      record.name = name
      record.hasCustomName = hasCustomName
      return true
    }
  }

  func setWorkspaceArchived(id: UUID, isArchived: Bool) async throws {
    try await request("archive:\(isArchived)")
    _ = try updateWorkspace(id) { record in
      record.isArchived = isArchived
      record.archivedAt = isArchived ? "2026-09-23T00:00:00.000Z" : nil
      return true
    }
  }

  /// Like the server: the move applies only if nobody reordered since the
  /// revision the device saw; otherwise the current order is returned.
  func reorderWorkspace(id: UUID, position: String, expectedRevision: Int) async throws -> ServerWorkspace {
    try await request("reorder:\(expectedRevision)")
    return try updateWorkspace(id) { record in
      let revision = record.sidebarOrderRevision ?? 1
      guard revision == expectedRevision else { return false }
      record.sidebarPosition = position
      record.sidebarOrderRevision = revision + 1
      return true
    }
  }

  func upsertWorkspacePane(_ pane: ServerWorkspacePane) async throws -> ServerWorkspacePane? {
    try await request("upsertPane:\(pane.paneType)")
    lock.withLock { _ = commitLocked(panes: [pane]) }
    return pane
  }

  func closeWorkspacePane(workspaceId: UUID, paneId: UUID) async throws -> ServerWorkspacePane? {
    try await request("closePane")
    try lock.withLock {
      guard state.panes.contains(where: { UUID(uuidString: $0.id) == paneId }) else {
        throw CodevisorServerClientError.httpStatus(404, "Missing pane")
      }
      _ = commitLocked(deleted: [("workspace_panes", paneId.uuidString)])
    }
    return nil
  }

  func promoteWorkspacePaneToChat(
    _ pane: ServerWorkspacePane, session: ChatSession
  ) async throws -> ServerWorkspacePanePromotion? {
    try await request("promotePane")
    return lock.withLock {
      guard state.panes.contains(where: { $0.id.caseInsensitiveCompare(pane.id) == .orderedSame }) else {
        return nil
      }
      var record = serverSession(from: session)
      record.workspaceId = pane.workspaceId
      _ = commitLocked(sessions: [record], panes: [pane])
      return ServerWorkspacePanePromotion(pane: pane, session: record)
    }
  }

  func upsertSession(_ session: ChatSession) async throws -> ServerSession {
    try await upsertSession(session, workspaceId: nil)
  }

  func upsertSession(_ session: ChatSession, workspaceId: UUID?) async throws -> ServerSession {
    try await request("upsertSession")
    return lock.withLock {
      var record = serverSession(from: session)
      record.workspaceId =
        workspaceId?.uuidString
        ?? state.sessions.first { UUID(uuidString: $0.id) == session.id }?.workspaceId
      _ = commitLocked(sessions: [record])
      return record
    }
  }

  func renameSession(_ session: ChatSession) async throws -> ServerSession {
    try await request("renameSession:\(session.title)")
    return try lock.withLock {
      guard var record = state.sessions.first(where: { UUID(uuidString: $0.id) == session.id }) else {
        throw CodevisorServerClientError.httpStatus(404, "Missing chat")
      }
      record.title = session.title
      _ = commitLocked(sessions: [record])
      return record
    }
  }

  func deleteSession(id: UUID) async throws {
    try await request("deleteSession")
    lock.withLock {
      let panes = state.panes.filter { $0.resourceKind == "session" && UUID(uuidString: $0.resourceId ?? "") == id }
      _ = commitLocked(deleted: [("sessions", id.uuidString)] + panes.map { ("workspace_panes", $0.id) })
    }
  }

  func listProjects() async throws -> [ServerProject] { current.projects }
  func listSessions() async throws -> [ServerSession] { current.sessions }

  // MARK: - Unused by navigation

  func health() async throws -> ServerHealth { ServerHealth(ok: true, version: "0.1.0", database: "ready") }
  func info() async throws -> ServerInfo { throw CodevisorServerClientError.invalidResponse }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    throw CodevisorServerClientError.invalidResponse
  }
  func issuePairingToken() async throws -> ServerPairingToken { throw CodevisorServerClientError.invalidResponse }
  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject { serverProject(from: project) }
  func updateProject(_ project: Project) async throws -> ServerProject { serverProject(from: project) }
  func deleteProject(id: UUID) async throws {}
  func updateSession(_ session: ChatSession) async throws -> ServerSession { try await upsertSession(session) }
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
  }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { $0.finish() }
  }
}

/// One machine with a project, a chat, and two workspaces, installed in a
/// `NavigationFixture` and backed by a `NavigationJournalServer` the outbox
/// sends to. `workspace` holds the chat; `otherWorkspace` is an empty
/// workspace on the same machine (a sidebar neighbour).
@MainActor
final class WorkspaceSyncFixture {
  let serverId = "local"
  let anchorSessionId = UUID()
  let project: Project
  let workspace: Workspace
  let otherWorkspace: Workspace
  let navigation: NavigationFixture
  let server: NavigationJournalServer

  var store: NavigationStore { navigation.store }
  var repository: ProjectedWorkspaceRepository { navigation.workspaces }
  var sync: WorkspaceSyncModel { navigation.workspaceSync }
  var projectList: ProjectListModel { navigation.projectList }
  /// The workspace as this device shows it right now.
  var current: Workspace? { repository.workspace(id: workspace.id) }

  init(
    persistence: InMemoryStore = InMemoryStore(),
    clock: any Clock<Duration> = ContinuousClock(),
    connected: Bool = false,
    customize: (inout Workspace, inout Workspace) -> Void = { _, _ in }
  ) async {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let project = Project(serverId: "local", name: "Shared", createdAt: createdAt)
    var workspace = Workspace(
      name: "Shared", rootDirectory: "/tmp/shared", serverId: "local", projectId: project.id,
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: anchorSessionId, paneId: anchorSessionId)))],
      createdAt: createdAt, isServerSynced: true)
    var other = Workspace(
      name: "Other", rootDirectory: "/tmp/other", serverId: "local", projectId: project.id,
      centerTabs: [.placeholder()], createdAt: createdAt.addingTimeInterval(10), isServerSynced: true)
    customize(&workspace, &other)
    self.project = project
    self.workspace = workspace
    otherWorkspace = other
    let session = ChatSession(id: anchorSessionId, projectId: project.id, serverId: "local", createdAt: createdAt)
    navigation = NavigationFixture(persistence: persistence, clock: clock)
    server = NavigationJournalServer(
      .fixture(projects: [project], sessions: [session], workspaces: [workspace, other]))
    await navigation.install(
      machineId: "local", projects: [project], sessions: [session], workspaces: [workspace, other])
    if connected { connect() }
  }

  /// The machine is reachable and current: the outbox may send to it.
  func connect() {
    let server = server
    store.executor.clientProvider = { _ in server }
    store.executor.isMachineReady = { _ in true }
  }

  func disconnect() {
    store.executor.isMachineReady = { _ in false }
  }

  /// Sends every waiting request that can be sent now.
  func flush() async {
    store.executor.resume(machineId: serverId)
    await store.executor.idle(machineId: serverId)
  }

  /// Delivers the server's events for everything it accepted.
  func deliver() async {
    await server.deliver(to: store, machineId: serverId)
  }

  func settle() async {
    await flush()
    await deliver()
  }

  func serverRecord(_ id: UUID) throws -> ServerWorkspace {
    guard let record = server.workspace(id) else {
      throw CodevisorServerClientError.httpStatus(404, "Missing workspace")
    }
    return record
  }
}
