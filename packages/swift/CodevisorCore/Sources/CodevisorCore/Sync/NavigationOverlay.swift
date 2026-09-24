import Foundation

/// One machine's navigation records: what the server last said, with the
/// outbox's waiting requests laid over it.
struct NavigationRecords: Sendable {
  var projects: [Project]
  var sessions: [ChatSession]
  var assignments: [UUID: UUID]
  var workspaces: [ServerWorkspace]
  var panes: [ServerWorkspacePane]

  init(_ cache: MachineNavigationCache?) {
    projects = cache?.projects ?? []
    sessions = cache?.sessions ?? []
    assignments = cache?.assignments ?? [:]
    workspaces = cache?.snapshot.workspaces ?? []
    panes = cache?.snapshot.panes ?? []
  }
}

/// Shows the user's waiting changes on top of the cached server state.
///
/// Each request has one small, obvious effect. Because the cache itself is
/// never touched, a request the server refuses simply stops being applied and
/// the server's state shows through again; nothing needs undoing.
enum NavigationOverlay {
  static func apply(_ entries: [NavigationOutboxEntry], to records: inout NavigationRecords) {
    for entry in entries { apply(entry.intent, to: &records) }
  }

  static func apply(_ intent: NavigationIntent, to records: inout NavigationRecords) {
    switch intent {
    case let .upsertProject(project):
      upsert(project, into: &records.projects)
    case let .deleteProject(projectId, sessionIds):
      let removed = Set(sessionIds)
      records.projects.removeAll { $0.id == projectId }
      records.sessions.removeAll { $0.projectId == projectId || removed.contains($0.id) }
    case let .upsertSession(session, workspaceId):
      upsertSession(session, into: &records)
      if let workspaceId { records.assignments[session.id] = workspaceId }
    case let .expectSession(session):
      if !records.sessions.contains(where: { $0.id == session.id }) { records.sessions.append(session) }
    case let .renameSession(session):
      updateSession(session.id, in: &records) { $0.title = session.title }
    case let .deleteSession(sessionId):
      records.sessions.removeAll { $0.id == sessionId }
      records.assignments.removeValue(forKey: sessionId)
      records.panes.removeAll { pane in
        pane.resourceKind == "session" && pane.resourceId.flatMap(UUID.init(uuidString:)) == sessionId
      }
    case let .markSessionRead(sessionId, throughSequence):
      updateSession(sessionId, in: &records) { markRead(&$0, through: throughSequence) }
    case let .markSessionUnread(sessionId):
      updateSession(sessionId, in: &records) { session in
        session.unreadCount = max(1, session.unreadCount)
        if session.sidebarState == .idle { session.sidebarState = .unread }
      }
    case let .renameWorkspace(workspaceId, name, hasCustomName):
      updateWorkspace(workspaceId, in: &records) {
        $0.name = name
        $0.hasCustomName = hasCustomName
      }
    case let .setWorkspaceArchived(workspaceId, isArchived):
      updateWorkspace(workspaceId, in: &records) {
        $0.isArchived = isArchived
        if !isArchived { $0.archivedAt = nil }
      }
    case let .reorderWorkspace(workspaceId, position, _):
      updateWorkspace(workspaceId, in: &records) { $0.sidebarPosition = position }
    case let .upsertPane(pane, workspaceId):
      upsertPane(pane, workspaceId: workspaceId, into: &records)
    case let .closePane(paneId, _):
      records.panes.removeAll { UUID(uuidString: $0.id) == paneId }
    case let .promotePane(pane, workspaceId, session):
      upsertSession(session, into: &records)
      records.assignments[session.id] = workspaceId
      upsertPane(pane, workspaceId: workspaceId, into: &records)
    }
  }

  /// The read state marking a chat read produces locally, identical to what
  /// the server will compute for the same sequence.
  static func markRead(_ session: inout ChatSession, through throughSequence: Int) {
    let rendered = min(max(0, throughSequence), session.latestAttentionSequence)
    session.lastSeenAttentionSequence = max(session.lastSeenAttentionSequence, rendered)
    session.unreadCount = max(0, session.latestAttentionSequence - session.lastSeenAttentionSequence)
    guard session.unreadCount == 0 else { return }
    session.hasUnreadError = false
    if session.actionRequired {
      session.sidebarState = .waitingForUser
    } else if session.sidebarState != .inProgress {
      session.sidebarState = .idle
    }
  }

  private static func upsert(_ project: Project, into projects: inout [Project]) {
    if let index = projects.firstIndex(where: { $0.id == project.id }) {
      projects[index] = project
    } else {
      projects.append(project)
    }
  }

  /// A chat the server already has keeps the server's attention state: the
  /// device's copy of those counters is older than the server's by definition.
  private static func upsertSession(_ session: ChatSession, into records: inout NavigationRecords) {
    guard let index = records.sessions.firstIndex(where: { $0.id == session.id }) else {
      records.sessions.append(session)
      return
    }
    var merged = session
    let current = records.sessions[index]
    merged.sidebarState = current.sidebarState
    merged.sidebarStateChangedAt = current.sidebarStateChangedAt
    merged.latestAttentionSequence = current.latestAttentionSequence
    merged.lastSeenAttentionSequence = current.lastSeenAttentionSequence
    merged.unreadCount = current.unreadCount
    merged.hasUnreadError = current.hasUnreadError
    merged.actionRequired = current.actionRequired
    merged.actionRequiredKind = current.actionRequiredKind
    merged.pendingPlanApproval = current.pendingPlanApproval
    records.sessions[index] = merged
  }

  private static func updateSession(
    _ id: UUID, in records: inout NavigationRecords, _ change: (inout ChatSession) -> Void
  ) {
    guard let index = records.sessions.firstIndex(where: { $0.id == id }) else { return }
    change(&records.sessions[index])
  }

  private static func updateWorkspace(
    _ id: UUID, in records: inout NavigationRecords, _ change: (inout ServerWorkspace) -> Void
  ) {
    guard let index = records.workspaces.firstIndex(where: { UUID(uuidString: $0.id) == id }) else { return }
    change(&records.workspaces[index])
  }

  private static func upsertPane(
    _ pane: PaneDescriptorState, workspaceId: UUID, into records: inout NavigationRecords
  ) {
    let createdAt =
      records.panes.first { UUID(uuidString: $0.id) == pane.id }
      .flatMap { try? ServerDateCoding.date(from: $0.createdAt) } ?? Date(timeIntervalSince1970: 0)
    let record = WorkspaceSyncModel.serverPane(from: pane, workspaceId: workspaceId, createdAt: createdAt)
    if let index = records.panes.firstIndex(where: { UUID(uuidString: $0.id) == pane.id }) {
      records.panes[index] = record
    } else {
      records.panes.append(record)
    }
  }
}
