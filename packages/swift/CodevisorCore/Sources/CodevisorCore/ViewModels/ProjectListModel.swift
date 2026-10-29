import Foundation
import Observation

@MainActor
@Observable
public final class ProjectListModel {
  public internal(set) var projects: [Project] = []
  @ObservationIgnored private var projectedProjects: [Project] = []
  @ObservationIgnored private var cloningProjects: [Project] = []
  public internal(set) var sessions: [ChatSession] = [] {
    didSet { sessionPositions = Self.positions(of: sessions) }
  }
  @ObservationIgnored private var sessionPositions: [SessionKey: Int] = [:]

  struct SessionKey: Hashable {
    let serverId: String
    let id: UUID
  }

  private static func positions(of sessions: [ChatSession]) -> [SessionKey: Int] {
    var positions: [SessionKey: Int] = [:]
    positions.reserveCapacity(sessions.count)
    for (index, session) in sessions.enumerated() {
      positions[SessionKey(serverId: session.serverId, id: session.id)] = index
    }
    return positions
  }
  public private(set) var selectedServerId: String
  @ObservationIgnored public var onAttentionTransition: ((SessionAttentionTransition) -> Void)?
  public var showsImportedSessions: Bool = true
  @ObservationIgnored var navigationStore: NavigationStore?

  public init(selectedServerId: String = "local") {
    self.selectedServerId = selectedServerId
  }

  func enqueue(
    _ intent: NavigationIntent, serverId: String, origin: SessionAttentionTransition.Origin = .snapshot
  ) {
    navigationStore?.enqueue(intent, machineId: serverId, origin: origin)
  }

  public func session(_ id: UUID, serverId: String) -> ChatSession? {
    sessionPositions[SessionKey(serverId: serverId, id: id)].map { sessions[$0] }
  }

  private func pendingSession(_ id: UUID, serverId: String) -> (session: ChatSession, isExpected: Bool)? {
    for entry in (navigationStore?.pendingIntents ?? []).reversed() where entry.machineId == serverId {
      switch entry.intent {
      case let .expectSession(session) where session.id == id: return (session, true)
      case let .upsertSession(session, _) where session.id == id: return (session, false)
      default: continue
      }
    }
    return self.session(id, serverId: serverId).map { ($0, false) }
  }

  @discardableResult
  public func newSession(
    in project: Project,
    title: String = "New Session",
    harnessId: String? = nil,
    worktreeName: String? = nil,
    cwd: String? = nil,
    syncToServer: Bool = true
  ) -> ChatSession {
    let session = ChatSession(
      projectId: project.id,
      serverId: project.serverId,
      harnessId: harnessId ?? "",
      title: title,
      origin: .codevisor,
      worktreeName: worktreeName,
      cwd: cwd
    )
    enqueue(
      syncToServer ? .upsertSession(session, workspaceId: nil) : .expectSession(session), serverId: session.serverId)
    return session
  }

  public func setWorktree(name: String, cwd: String, for sessionId: UUID, serverId: String) {
    guard var pending = pendingSession(sessionId, serverId: serverId) else { return }
    pending.session.worktreeName = name
    pending.session.cwd = cwd
    enqueue(
      pending.isExpected ? .expectSession(pending.session) : .upsertSession(pending.session, workspaceId: nil),
      serverId: serverId)
  }

  public func setAgentSessionId(_ agentSessionId: String, for sessionId: UUID, serverId: String) {
    guard var pending = pendingSession(sessionId, serverId: serverId) else { return }
    pending.session.agentSessionId = agentSessionId
    enqueue(.upsertSession(pending.session, workspaceId: nil), serverId: serverId)
  }

  @discardableResult
  public func updateSessionForFirstSend(
    _ session: ChatSession,
    title: String,
    harnessId: String?
  ) -> ChatSession? {
    guard var pending = pendingSession(session.id, serverId: session.serverId) else { return nil }
    if pending.session.title == "New Chat" { pending.session.title = title }
    if let harnessId { pending.session.harnessId = harnessId }
    enqueue(.upsertSession(pending.session, workspaceId: nil), serverId: session.serverId)
    return pending.session
  }

  public func deleteSession(_ session: ChatSession) {
    enqueue(.deleteSession(sessionId: session.id), serverId: session.serverId)
  }

  public func removeAll() {
    for project in projects where project.serverId == selectedServerId { removeProject(project) }
  }

  @discardableResult
  public func markSessionRead(
    _ sessionId: UUID,
    serverId: String,
    throughSequence: Int? = nil
  ) -> Task<Void, Never>? {
    guard let before = session(sessionId, serverId: serverId) else { return nil }
    let rendered = min(
      max(0, throughSequence ?? before.latestAttentionSequence), before.latestAttentionSequence)
    guard before.unreadCount > 0 || before.hasUnreadError || rendered > before.lastSeenAttentionSequence
    else { return nil }
    enqueue(
      .markSessionRead(sessionId: sessionId, throughSequence: rendered), serverId: serverId, origin: .localMarkRead)
    return nil
  }

  @discardableResult
  public func markSessionUnread(_ sessionId: UUID, serverId: String) -> Task<Void, Never>? {
    guard session(sessionId, serverId: serverId) != nil else { return nil }
    enqueue(.markSessionUnread(sessionId: sessionId), serverId: serverId, origin: .localMarkUnread)
    return nil
  }

  public func acknowledgePresentedTurnEnd(_ sessionId: UUID, serverId: String, throughSequence: Int) {
    guard let session = session(sessionId, serverId: serverId),
      session.lastSeenAttentionSequence < throughSequence
    else { return }
    enqueue(
      .markSessionRead(sessionId: sessionId, throughSequence: throughSequence), serverId: serverId,
      origin: .localMarkRead)
  }

  func emitAttentionTransition(
    old: ChatSession?,
    new: ChatSession,
    origin: SessionAttentionTransition.Origin
  ) {
    let oldSummary = old.map(SessionAttentionSummary.init)
    let newSummary = SessionAttentionSummary(new)
    guard oldSummary != newSummary else { return }
    onAttentionTransition?(
      SessionAttentionTransition(
        sessionId: new.id,
        serverId: new.serverId,
        old: oldSummary,
        new: newSummary,
        origin: origin
      ))
  }

  func emitAttentionTransitions(
    from previous: [ChatSession],
    to next: [ChatSession],
    origin: SessionAttentionTransition.Origin
  ) {
    var old: [SessionKey: ChatSession] = [:]
    old.reserveCapacity(previous.count)
    for session in previous { old[SessionKey(serverId: session.serverId, id: session.id)] = session }
    for session in next {
      emitAttentionTransition(
        old: old[SessionKey(serverId: session.serverId, id: session.id)], new: session, origin: origin)
    }
  }

  @discardableResult
  public func refreshFromServer(
    serverId: String, client: any CodevisorServerClienting
  ) async -> ServerNavigationRefreshResult {
    guard let navigationStore else { return .failed("No navigation store") }
    return await navigationStore.refresh(machineId: serverId, client: client)
  }

  public func workspaceId(forSession sessionId: UUID) -> UUID? {
    navigationStore?.projection.sessionIndex[sessionId]
  }

  public func mainChat(of item: WorkspaceSidebarItem) -> ChatSession? {
    var hidden: ChatSession?
    for id in item.routingChatIds {
      guard let chat = session(id, serverId: item.serverId) else { continue }
      if chat.origin == .codevisor || showsImportedSessions { return chat }
      if hidden == nil { hidden = chat }
    }
    return hidden
  }

  public func workspaceAssignments(for serverId: String) -> [UUID: UUID] {
    guard let projection = navigationStore?.projection else { return [:] }
    var assignments: [UUID: UUID] = [:]
    for session in sessions where session.serverId == serverId {
      if let workspaceId = projection.sessionIndex[session.id] { assignments[session.id] = workspaceId }
    }
    return assignments
  }

  public func fleetSessions(in project: Project) -> [ChatSession] {
    sessions
      .filter { session in
        session.projectId == project.id
          && session.serverId == project.serverId
          && (session.origin == .codevisor || showsImportedSessions)
      }
      .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
  }

  public var fleetActiveProjects: [Project] {
    projects
      .filter { !$0.isBot && !isCloning($0) && ($0.origin == .codevisor || !fleetSessions(in: $0).isEmpty) }
      .sorted { $0.createdAt > $1.createdAt }
  }

  public func showCloningProject(_ project: Project) {
    cloningProjects.removeAll { $0.serverId == project.serverId && $0.id == project.id }
    cloningProjects.append(project)
    publishProjects()
  }

  private func isCloning(_ project: Project) -> Bool {
    cloningProjects.contains { $0.serverId == project.serverId && $0.id == project.id }
  }

  private func publishProjects() {
    cloningProjects.removeAll { cloning in
      projectedProjects.contains { $0.serverId == cloning.serverId && $0.id == cloning.id }
    }
    let next = projectedProjects + cloningProjects
    if next != projects { projects = next }
  }

  public func fleetActiveProjectsByWorkspaceRecency(
    _ workspaces: [Workspace]
  ) -> [Project] {
    var latestWorkspaceDates: [String: Date] = [:]
    for workspace in workspaces {
      let key = "\(workspace.serverId)|\(workspace.projectId.uuidString)"
      latestWorkspaceDates[key] = max(
        latestWorkspaceDates[key] ?? .distantPast,
        workspace.createdAt
      )
    }
    return fleetActiveProjects.enumerated().sorted { left, right in
      let leftKey = "\(left.element.serverId)|\(left.element.id.uuidString)"
      let rightKey = "\(right.element.serverId)|\(right.element.id.uuidString)"
      switch (latestWorkspaceDates[leftKey], latestWorkspaceDates[rightKey]) {
      case let (leftDate?, rightDate?) where leftDate != rightDate:
        return leftDate > rightDate
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        return left.offset < right.offset
      }
    }
    .map(\.element)
  }

  public func removeAllRecords(serverId: String) {
    navigationStore?.forget(machineId: serverId)
  }

  @discardableResult
  public func addProject(
    folderURL: URL,
    serverId: String,
    client: any CodevisorServerClienting
  ) async -> Project {
    let local = addProject(folderURL: folderURL, serverId: serverId)
    do {
      let probed = try await client.upsertProject(local).project(serverId: serverId)
      var merged = local
      merged.locations = probed.locations
      merged.repoUrl = probed.repoUrl
      merged.repoKey = probed.repoKey
      return merged
    } catch {
      Log.sync.error(
        "Couldn't probe project \(local.id.uuidString, privacy: .public) yet: \(String(describing: error), privacy: .public)"
      )
      return local
    }
  }

  private static let fractionalImportTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let wholeSecondImportTimestampFormatter = ISO8601DateFormatter()

  public func importSessions(_ imported: [ImportedSession], into project: Project) {
    for item in imported {
      if let known = sessions.first(where: {
        $0.serverId == project.serverId
          && $0.harnessId == item.harnessId
          && $0.agentSessionId == item.info.sessionId
      }) {
        reconcileImportedActivity(item, of: known)
        continue
      }
      let timestamp = Self.importTimestamp(item.info.updatedAt)
      importSession(
        item.chatSession(projectId: project.id, serverId: project.serverId, timestamp: timestamp))
    }
  }

  private func importSession(_ session: ChatSession) {
    enqueue(.upsertSession(session, workspaceId: nil), serverId: session.serverId)
  }

  private func reconcileImportedActivity(_ item: ImportedSession, of known: ChatSession) {
    guard let discoveredAt = Self.importTimestamp(item.info.updatedAt),
      discoveredAt > known.updatedAt ?? known.createdAt
    else { return }
    var updated = known
    updated.updatedAt = discoveredAt
    importSession(updated)
  }

  private static func importTimestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    return fractionalImportTimestampFormatter.date(from: value)
      ?? wholeSecondImportTimestampFormatter.date(from: value)
  }

  func applyProjection(
    projects nextProjects: [Project], sessions nextSessions: [ChatSession],
    origin: SessionAttentionTransition.Origin
  ) {
    projectedProjects = nextProjects
    publishProjects()
    guard nextSessions != sessions else { return }
    let previous = sessions
    sessions = nextSessions
    emitAttentionTransitions(from: previous, to: nextSessions, origin: origin)
  }

  public func isProjectDeleted(id: UUID, serverId: String) -> Bool {
    navigationStore?.pendingIntents.contains { entry in
      guard entry.machineId == serverId, case let .deleteProject(projectId, _, _) = entry.intent else { return false }
      return projectId == id
    } ?? false
  }

  public func registeredFolderPaths(serverId: String) -> Set<String> {
    Set(
      fleetActiveProjects
        .filter { $0.serverId == serverId && !$0.isScratch }
        .map { $0.folderURL.standardizedFileURL.path }
    )
  }

  @discardableResult
  public func addProject(folderURL: URL) -> Project {
    addProject(folderURL: folderURL, serverId: selectedServerId)
  }

  @discardableResult
  public func addProject(folderURL: URL, serverId: String) -> Project {
    if let existing = projects.first(where: { $0.serverId == serverId && $0.folderURL == folderURL }) {
      return existing
    }
    let project = Project.fromFolder(folderURL, serverId: serverId)
    enqueue(.upsertProject(project), serverId: serverId)
    return project
  }

  @discardableResult
  public func adoptServerProject(
    id: UUID, folderURL: URL, name: String, serverId: String? = nil
  ) -> Project {
    let server = serverId ?? selectedServerId
    if let existing = projects.first(where: { $0.serverId == server && $0.id == id }) { return existing }
    var project = Project.fromFolder(folderURL, serverId: server)
    project.id = id
    project.name = name
    project.locations = project.locations.map { location in
      var updated = location
      updated.projectId = id
      return updated
    }
    enqueue(.upsertProject(project), serverId: server)
    return project
  }

  public func registerServerProject(_ project: Project) {
    enqueue(.upsertProject(project), serverId: project.serverId)
  }

  public func removeProject(_ project: Project, deletingFiles: Bool = false) {
    let sessionIds = sessions.filter { $0.serverId == project.serverId && $0.projectId == project.id }.map(\.id)
    enqueue(
      .deleteProject(projectId: project.id, sessionIds: sessionIds, deletesFiles: deletingFiles ? true : nil),
      serverId: project.serverId)
  }

  public func removeProjectGroup(_ group: ProjectGroup, deletingFiles: Bool = false) {
    for project in group.members { removeProject(project, deletingFiles: deletingFiles) }
  }

  public func setWorktreeBase(_ base: ProjectWorktreeBase, for group: ProjectGroup) {
    for project in group.members where project.isGitRepository && project.worktreeBase != base {
      enqueue(.setProjectWorktreeBase(projectId: project.id, worktreeBase: base), serverId: project.serverId)
    }
  }

  public func setDefaultRunLocation(_ location: ProjectRunLocation, for group: ProjectGroup) {
    for project in group.members where project.isGitRepository && project.defaultRunLocation != location {
      enqueue(
        .setProjectDefaultRunLocation(projectId: project.id, location: location),
        serverId: project.serverId
      )
    }
  }

  public func alignWorktreeBase(for group: ProjectGroup) {
    let chosen = group.members.filter(\.isGitRepository).contains { $0.worktreeBase != nil }
    guard chosen else { return }
    setWorktreeBase(group.worktreeBase, for: group)
  }

  @discardableResult
  public func renameSession(
    _ session: ChatSession, to title: String, errorReporter: ErrorReporter = .shared
  ) -> Task<Void, Never>? {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, var current = self.session(session.id, serverId: session.serverId) else { return nil }
    current.title = title
    enqueue(.renameSession(current), serverId: session.serverId)
    return nil
  }
}
