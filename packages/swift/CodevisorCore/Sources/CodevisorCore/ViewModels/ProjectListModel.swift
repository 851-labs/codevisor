import Foundation
import Observation

/// The sidebar's projects and chats across every machine.
///
/// It shows what `NavigationStore` derives and nothing else: `projects` and
/// `sessions` are never edited here. Every change the user makes becomes an
/// outbox request, which the store shows at once and sends to the machine
/// that owns the record.
@MainActor
@Observable
public final class ProjectListModel {
  public internal(set) var projects: [Project] = []
  public internal(set) var sessions: [ChatSession] = []
  public private(set) var selectedServerId: String
  /// Fires whenever a session's attention state changes, from every path
  /// that can change it (live events, snapshots, local mutations).
  /// `SessionAttentionCoordinator` consumes these to drive focus auto-read
  /// and edge-triggered notifications.
  @ObservationIgnored public var onAttentionTransition: ((SessionAttentionTransition) -> Void)?
  /// Whether imported (non-Codevisor) sessions are shown. Synced from settings.
  public var showsImportedSessions: Bool = true
  @ObservationIgnored var navigationStore: NavigationStore?

  public init(selectedServerId: String = "local") {
    self.selectedServerId = selectedServerId
  }

  /// Sends a change to the machine that owns it, showing it immediately.
  func enqueue(
    _ intent: NavigationIntent, serverId: String, origin: SessionAttentionTransition.Origin = .snapshot
  ) {
    navigationStore?.enqueue(intent, machineId: serverId, origin: origin)
  }

  func session(_ id: UUID, serverId: String) -> ChatSession? {
    sessions.first { $0.serverId == serverId && $0.id == id }
  }

  /// The chat as it will look once waiting changes land: a chat that is
  /// still only in the outbox is found there too.
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
      // Inherit the project's server: a machine switch between opening
      // the composer and sending must not file the session elsewhere.
      serverId: project.serverId,
      harnessId: harnessId ?? "",
      title: title,
      origin: .codevisor,
      worktreeName: worktreeName,
      cwd: cwd
    )
    // A chat whose open request will create it isn't sent separately: two
    // concurrent creates of one chat would race.
    enqueue(
      syncToServer ? .upsertSession(session, workspaceId: nil) : .expectSession(session), serverId: session.serverId)
    return session
  }

  /// Records the worktree a draft session ended up running in. The session
  /// record is created before the worktree exists (the session page opens
  /// while setup streams progress), so the name/cwd land here afterwards,
  /// in the waiting request the first open carries.
  public func setWorktree(name: String, cwd: String, for sessionId: UUID, serverId: String) {
    guard var pending = pendingSession(sessionId, serverId: serverId) else { return }
    pending.session.worktreeName = name
    pending.session.cwd = cwd
    enqueue(
      pending.isExpected ? .expectSession(pending.session) : .upsertSession(pending.session, workspaceId: nil),
      serverId: serverId)
  }

  /// Records the agent-side session id once a brand-new session is created.
  public func setAgentSessionId(_ agentSessionId: String, for sessionId: UUID, serverId: String) {
    guard var pending = pendingSession(sessionId, serverId: serverId) else { return }
    pending.session.agentSessionId = agentSessionId
    enqueue(.upsertSession(pending.session, workspaceId: nil), serverId: serverId)
  }

  /// Fills in an eagerly created session's first-send details. Workspace
  /// "New Chat" tabs register their session at CREATION (so the sidebar
  /// shows them immediately, already stamped with the workspace's
  /// worktree/cwd) but keep the new-chat composer until the first message —
  /// which is when the title and chosen harness become known. A manual
  /// rename before the first message wins over the prompt-derived title.
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

  /// Deletes every project and chat on the selected machine ("Delete all
  /// data").
  public func removeAll() {
    for project in projects where project.serverId == selectedServerId { removeProject(project) }
  }
}
