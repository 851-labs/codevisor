import Observation
import CodevisorTestSupport
import ACPKit
import Foundation

@testable import CodevisorCore

/// A fake server whose event stream and list endpoints are test-driven.
/// Shared by the MachineController suites (sync, panes, self-updates).
@Observable
final class SyncFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  var _infoCloudDeviceId: String?
  var _infoFeatures: [String]?
  /// Tests that need capability responses (or to delay them) install one.
  var capabilitiesHandler: (@Sendable (String) async throws -> ServerCapabilities)?
  var resolvedCapabilitiesHandler: (@Sendable (String, String, [String: String]) async throws -> ServerCapabilities)?
  /// Tests exercising composer attachments install one; the protocol
  /// default rejects uploads.
  var uploadFileHandler: (@Sendable (String, String, Data) async throws -> ServerFileMetadata)?
  var workspaceOrderHandler: (@Sendable (UUID, String, Int) async throws -> ServerWorkspace)?
  var workspaceSnapshotHandler: (@Sendable () async throws -> ServerWorkspaceSnapshot?)?
  var workspaceRenameHandler: (@Sendable (UUID, String, Bool) async throws -> Void)?
  var sessionRenameHandler: (@Sendable (ChatSession) async throws -> Void)?
  private var _workspaceRenameNames: [String] = []
  private var _sessionRenameNames: [String] = []
  var workspaceRenameNames: [String] { lock.withLock { _workspaceRenameNames } }
  var sessionRenameNames: [String] { lock.withLock { _sessionRenameNames } }

  var harnessUpdateHandler: (@Sendable (String) async throws -> ServerHarnessOperationStarted)?
  var pluginPrepareError: String?
  var applyProgressReports: [ServerUpdateApplyState] = []
  var applyingProgressReports = false
  let lock = NSLock()
  private var _projects: [ServerProject]
  var _sessions: [ServerSession]
  private var _workspaces: [ServerWorkspace]
  var _panes: [ServerWorkspacePane]?
  private var continuations: [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation] = []
  private var emittedEvents: [ServerEventEnvelope] = []
  var nextEventId = 1
  private var _listSessionCallCount = 0
  private var _workspaceSnapshotCallCount = 0
  var paneUpsertGate: TestSignal?
  let paneUpsertStarted = TestSignal()
  var panePromotionGate: TestSignal?
  let panePromotionStarted = TestSignal()
  var paneCloseGate: TestSignal?
  let paneCloseStarted = TestSignal()
  private var _paneMutationLog: [String] = []

  init(
    projects: [ServerProject],
    sessions: [ServerSession],
    workspaces: [ServerWorkspace] = [],
    panes: [ServerWorkspacePane]? = nil
  ) {
    _projects = projects
    _sessions = sessions
    _workspaces = workspaces
    _panes = panes
  }

  func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata {
    guard let uploadFileHandler else { throw CodevisorServerClientError.invalidResponse }
    return try await uploadFileHandler(name, mimeType, data)
  }

  func setSessions(_ sessions: [ServerSession]) {
    lock.withLock { _sessions = sessions }
  }

  func setProjects(_ projects: [ServerProject]) {
    lock.withLock { _projects = projects }
  }

  func setWorkspaces(_ workspaces: [ServerWorkspace]) {
    lock.withLock { _workspaces = workspaces }
  }

  func setPanes(_ panes: [ServerWorkspacePane]) {
    lock.withLock { _panes = panes }
  }

  var listSessionCallCount: Int { lock.withLock { _listSessionCallCount } }
  /// How many event-stream subscriptions are currently attached.
  var eventStreamSubscriberCount: Int { lock.withLock { continuations.count } }
  var workspaceSnapshotCallCount: Int { lock.withLock { _workspaceSnapshotCallCount } }
  var sessions: [ServerSession] { lock.withLock { _sessions } }
  var workspaces: [ServerWorkspace] { lock.withLock { _workspaces } }
  var workspacePanes: [ServerWorkspacePane]? { lock.withLock { _panes } }
  var paneMutationLog: [String] { lock.withLock { _paneMutationLog } }

  func emit(kind: String, subjectId: String, payload: JSONValue = .null) {
    let (event, targets): (ServerEventEnvelope, [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation]) =
      lock.withLock {
        let navigation = navigationEvent(kind: kind, subjectId: subjectId, payload: payload)
        let event = ServerEventEnvelope(
          id: nextEventId,
          serverId: "local",
          kind: navigation == nil ? kind : "navigation.changed",
          subjectId: subjectId,
          createdAt: "2026-06-30T00:00:02.000Z",
          payload: navigation ?? payload
        )
        nextEventId += 1
        emittedEvents.append(event)
        return (event, continuations)
      }
    for continuation in targets {
      continuation.yield(event)
    }
  }

  func latestShellEventCursor() async throws -> Int {
    lock.withLock { nextEventId - 1 }
  }

  func finishEventStreams(throwing error: (any Error)? = nil) {
    let targets = lock.withLock {
      let targets = continuations
      continuations.removeAll()
      return targets
    }
    for continuation in targets { continuation.finish(throwing: error) }
  }

  /// Mirrors the real server: replays the event log from `since`, then
  /// streams new events.
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { continuation in
      let backlog: [ServerEventEnvelope] = lock.withLock {
        continuations.append(continuation)
        return emittedEvents.filter { $0.id > since }
      }
      for event in backlog {
        continuation.yield(event)
      }
    }
  }

  func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    let cursor = lock.withLock { nextEventId - 1 }
    let snapshot = try await workspaceSnapshot()
    let workspaces: [ServerWorkspace]
    let panes: [ServerWorkspacePane]
    if let snapshot {
      workspaces = snapshot.workspaces; panes = snapshot.panes
    } else {
      workspaces = try await listWorkspaces() ?? []; panes = try await listWorkspacePanes() ?? []
    }
    return ServerNavigationSnapshot(
      eventCursor: cursor, projects: try await listProjects(), sessions: try await listSessions(),
      workspaces: workspaces, panes: panes)
  }

  /// Test mutations emit the same entity delta as the database journal.
  private func navigationEvent(kind: String, subjectId: String, payload: JSONValue) -> JSONValue? {
    let table: String
    if kind.hasPrefix("workspace.pane.") {
      table = "workspace_panes"
    } else if kind.hasPrefix("workspace.") {
      table = "workspaces"
    } else if kind.hasPrefix("session.") && kind != "session.output" {
      table = "sessions"
    } else if kind.hasPrefix("project.") && kind != "project.setup" {
      table = "projects"
    } else {
      return nil
    }
    func same(_ id: String) -> Bool { id.caseInsensitiveCompare(subjectId) == .orderedSame }
    let record: JSONValue?
    if payload["id"]?.stringValue != nil {
      record = payload
    } else {
      switch table {
      case "workspaces": record = _workspaces.first(where: { same($0.id) }).map(navigationFixtureJSON)
      case "workspace_panes": record = _panes?.first(where: { same($0.id) }).map(navigationFixtureJSON)
      case "sessions": record = _sessions.first(where: { same($0.id) }).map(navigationFixtureJSON)
      default: record = _projects.first(where: { same($0.id) }).map(navigationFixtureJSON)
      }
    }
    var deleted: [JSONValue] = []
    if kind.hasSuffix(".deleted") {
      func remove(_ table: String, _ id: String) {
        deleted.append(.object(["table": .string(table), "id": .string(id)]))
      }
      remove(table, subjectId)
      let workspaces =
        table == "projects"
        ? _workspaces.filter { same($0.projectId) }.map(\.id) : table == "workspaces" ? [subjectId] : []
      for id in workspaces where id != subjectId { remove("workspaces", id) }
      for pane in _panes ?? []
      where workspaces.contains(where: { $0.caseInsensitiveCompare(pane.workspaceId) == .orderedSame })
        || (table == "sessions" && pane.resourceKind == "session" && same(pane.resourceId ?? ""))
      {
        remove("workspace_panes", pane.id)
      }
      if table == "projects" {
        for session in _sessions where same(session.projectId) { remove("sessions", session.id) }
      }
    }
    var result: [String: JSONValue] = [
      "eventCursor": .number(Double(nextEventId)),
      "projects": .array([]), "sessions": .array([]), "workspaces": .array([]), "panes": .array([]),
      "deleted": .array(deleted),
    ]
    if deleted.isEmpty, let record { result[table == "workspace_panes" ? "panes" : table] = .array([record]) }
    return .object(result)
  }

  func listProjects() async throws -> [ServerProject] { lock.withLock { _projects } }
  func listSessions() async throws -> [ServerSession] {
    lock.withLock {
      _listSessionCallCount += 1
      return _sessions
    }
  }
  func listWorkspaces() async throws -> [ServerWorkspace]? { lock.withLock { _workspaces } }
  func workspaceSnapshot() async throws -> ServerWorkspaceSnapshot? {
    let handler = lock.withLock {
      _workspaceSnapshotCallCount += 1
      return workspaceSnapshotHandler
    }
    if let handler { return try await handler() }
    return lock.withLock {
      return ServerWorkspaceSnapshot(workspaces: _workspaces, panes: _panes ?? [])
    }
  }
  func upsertWorkspace(_ workspace: ServerWorkspace) async throws -> ServerWorkspace? {
    lock.withLock {
      _workspaces.removeAll {
        $0.id.caseInsensitiveCompare(workspace.id) == .orderedSame
      }
      _workspaces.append(workspace)
      return workspace
    }
  }
  func reorderWorkspace(id: UUID, position: String, expectedRevision: Int) async throws -> ServerWorkspace {
    let handler = lock.withLock { workspaceOrderHandler }
    if let handler { return try await handler(id, position, expectedRevision) }
    return try lock.withLock {
      guard let index = _workspaces.firstIndex(where: { UUID(uuidString: $0.id) == id }) else {
        throw CodevisorServerClientError.httpStatus(404, "Missing workspace")
      }
      if _workspaces[index].sidebarOrderRevision == expectedRevision {
        _workspaces[index].sidebarPosition = position
        _workspaces[index].sidebarOrderRevision = expectedRevision + 1
      }
      return _workspaces[index]
    }
  }
  func renameWorkspace(id: UUID, name: String, hasCustomName: Bool) async throws {
    let handler = lock.withLock {
      _workspaceRenameNames.append(name)
      return workspaceRenameHandler
    }
    try await handler?(id, name, hasCustomName)
    try lock.withLock {
      guard let index = _workspaces.firstIndex(where: { UUID(uuidString: $0.id) == id }) else {
        throw CodevisorServerClientError.httpStatus(404, "Missing workspace")
      }
      _workspaces[index].name = name
      _workspaces[index].hasCustomName = hasCustomName
    }
  }
  func renameSession(_ session: ChatSession) async throws -> ServerSession {
    let handler = lock.withLock {
      _sessionRenameNames.append(session.title)
      return sessionRenameHandler
    }
    try await handler?(session)
    return try lock.withLock {
      guard let index = _sessions.firstIndex(where: { UUID(uuidString: $0.id) == session.id }) else {
        throw CodevisorServerClientError.httpStatus(404, "Missing chat")
      }
      _sessions[index].title = session.title
      return _sessions[index]
    }
  }
  func listWorkspacePanes() async throws -> [ServerWorkspacePane]? { lock.withLock { _panes } }
  func upsertWorkspacePane(_ pane: ServerWorkspacePane) async throws -> ServerWorkspacePane? {
    let gate = lock.withLock {
      _paneMutationLog.append("upsert")
      return paneUpsertGate
    }
    paneUpsertStarted.signal()
    await gate?.wait()
    return lock.withLock { () -> ServerWorkspacePane? in
      guard _panes != nil else { return nil }
      _panes?.removeAll { $0.id.caseInsensitiveCompare(pane.id) == .orderedSame }
      _panes?.append(pane)
      return pane
    }
  }

  func promoteWorkspacePaneToChat(
    _ pane: ServerWorkspacePane,
    session: ChatSession
  ) async throws -> ServerWorkspacePanePromotion? {
    let gate = lock.withLock { panePromotionGate }
    panePromotionStarted.signal()
    await gate?.wait()
    return lock.withLock {
      guard
        let paneIndex = _panes?.firstIndex(where: {
          $0.id.caseInsensitiveCompare(pane.id) == .orderedSame
        }),
        let sessionIndex = _sessions.firstIndex(where: {
          UUID(uuidString: $0.id) == session.id
        })
      else { return nil }
      var promoted = pane
      promoted.revision = (_panes?[paneIndex].revision ?? 0) + 1
      _panes?[paneIndex] = promoted
      _sessions[sessionIndex].workspaceId = pane.workspaceId
      return ServerWorkspacePanePromotion(
        pane: promoted,
        session: _sessions[sessionIndex]
      )
    }
  }

  func deleteWorkspacePane(workspaceId _: UUID, paneId: UUID) async throws {
    lock.withLock {
      _panes?.removeAll {
        $0.id.caseInsensitiveCompare(paneId.uuidString) == .orderedSame
      }
    }
  }

  func closeWorkspacePane(workspaceId: UUID, paneId: UUID) async throws -> ServerWorkspacePane? {
    let gate = lock.withLock {
      _paneMutationLog.append("close")
      return paneCloseGate
    }
    paneCloseStarted.signal()
    await gate?.wait()
    return lock.withLock { () -> ServerWorkspacePane? in
      guard let panes = _panes else { return nil }
      let workspacePaneIndices = panes.indices.filter {
        panes[$0].workspaceId.caseInsensitiveCompare(workspaceId.uuidString) == .orderedSame
      }
      guard
        let index = workspacePaneIndices.first(where: {
          panes[$0].id.caseInsensitiveCompare(paneId.uuidString) == .orderedSame
        })
      else { return nil }
      // Like the server: a close is a deletion, even of the last pane. The
      // New Tab page a client shows for an empty workspace is its own.
      _panes?.remove(at: index)
      return nil
    }
  }

  // MARK: - Simulated server versioning / self-update

  var currentVersion = "0.1.0"
  var latestVersion = "0.1.0"
  var installedVersionAfterUpdate: String?
  /// The build the simulated restart lands on when it differs from the
  /// accepted target (an installer that resumed an older download).
  var installedBuildNumberAfterUpdate: Int?
  var updateApplied = false
  var bootId = "boot-before-update"
  var downtimeRemaining = 0
  /// How many `info()` probes a simulated restart refuses before answering.
  var restartDowntime = 3
  /// Simulated boot listener: while active, `health()` answers with the
  /// next migration report (`ok: false`, `database: "migrating"`) and every
  /// other route is refused with 503, exactly as a server booting through
  /// its data upgrades does. Armed reports activate on the next restart.
  var _migrationReports: [ServerMigrationProgress] = []
  var _migrationFailure: String?
  var _migrationArmed = false
  var _migrationActive = false
  var _infoId = "local"
  var _appliedUpdates = 0
  var _updateInfoChannels: [ServerUpdateChannel] = []
  var _updateInfoRefreshes: [Bool] = []
  var _appliedChannels: [ServerUpdateChannel] = []
  var _busy = false
  /// Simulated restart drain: `applyServerUpdate` accepts but the server
  /// reports "draining" for this many update-info polls before restarting.
  var _drainPollsRemaining = 0
  /// Simulated in-flight harness update: inventory reads report the
  /// harness as "updating" for this many reads after a trigger.
  var _harnessLifecycleActivePolls = 0
  var _harnessLifecycleReads = 0
  var currentBuildNumber: Int?
  var targetBuildNumber: Int?
  var applyFailureMessage: String?
  var lastApply: ServerUpdateApplyState?
  var _harnesses: [ServerHarness] = []
  var _pluginUpdates: [ServerPluginUpdateStatus] = []
  var _operationLog: [String] = []
  var _harnessesSyncApplied: [String] = []
  var _syncEntries: [String: [ServerSyncEntry]] = [:]
  var _skillBlobs: [String: Data] = [:]
  var _wantedSkills: [(directoryName: String, hash: String)] = []
  var _appliedSkillHashes: Set<String> = []

  struct ServerDownError: Error {}
}
