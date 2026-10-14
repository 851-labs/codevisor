import Foundation
import Observation

@MainActor
@Observable
public final class ProjectListModel {
  public internal(set) var projects: [Project] = []
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
}
