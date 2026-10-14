import Foundation

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

enum NavigationOverlay {
  static func apply(_ entries: [NavigationOutboxEntry], to records: inout NavigationRecords) {
    for entry in entries { apply(entry.intent, to: &records) }
  }

  static func apply(_ intent: NavigationIntent, to records: inout NavigationRecords) {
    switch intent {
    case let .upsertProject(project):
      upsert(project, into: &records.projects)
    case let .deleteProject(projectId, sessionIds, _):
      let removed = Set(sessionIds)
      records.projects.removeAll { $0.id == projectId }
      records.sessions.removeAll { $0.projectId == projectId || removed.contains($0.id) }
    case let .setProjectWorktreeBase(projectId, worktreeBase):
      if let index = records.projects.firstIndex(where: { $0.id == projectId }) {
        records.projects[index].worktreeBase = worktreeBase
      }
    case let .setProjectDefaultRunLocation(projectId, location):
      if let index = records.projects.firstIndex(where: { $0.id == projectId }) {
        records.projects[index].defaultRunLocation = location
      }
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
    case let .movePane(paneId, _, position):
      if let index = records.panes.firstIndex(where: { UUID(uuidString: $0.id) == paneId }) {
        records.panes[index].position = position
      }
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
    let current = records.panes.first { UUID(uuidString: $0.id) == pane.id }
    let createdAt =
      current.flatMap { try? ServerDateCoding.date(from: $0.createdAt) } ?? Date(timeIntervalSince1970: 0)
    var record = WorkspaceSyncModel.serverPane(from: pane, workspaceId: workspaceId, createdAt: createdAt)
    record.liveTitle = current?.liveTitle
    record.terminalActivity = current?.terminalActivity
    if let index = records.panes.firstIndex(where: { UUID(uuidString: $0.id) == pane.id }) {
      record.position = records.panes[index].position
      records.panes[index] = record
    } else {
      records.panes.append(record)
    }
  }
}
