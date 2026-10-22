import Foundation
import Observation

public struct SessionAttentionFocus: Hashable, Sendable {
  public let serverId: String
  public let sessionId: UUID

  public init(serverId: String, sessionId: UUID) {
    self.serverId = serverId
    self.sessionId = sessionId
  }
}

@MainActor
@Observable
public final class SessionAttentionCoordinator {
  @ObservationIgnored public var notificationDelivery: (any ChatNotificationDelivering)?
  @ObservationIgnored public var announcementFilter: ((SessionAttentionFocus, Set<SessionAttentionFocus>) -> Bool)?

  private let projectList: ProjectListModel
  private var focusByOwner: [ObjectIdentifier: SessionAttentionFocus] = [:]
  private var openByOwner: [ObjectIdentifier: SessionAttentionFocus] = [:]
  private var applicationActive = true
  private var manualUnreadHold: SessionAttentionFocus?

  public init(projectList: ProjectListModel) {
    self.projectList = projectList
    projectList.onAttentionTransition = { [weak self] transition in
      self?.handle(transition)
    }
  }

  public var focusedSession: SessionAttentionFocus? {
    focusByOwner.values.first
  }

  public func updateFocus(owner: ObjectIdentifier, session: SessionAttentionFocus?) {
    if let session {
      focusByOwner[owner] = session
    } else {
      focusByOwner.removeValue(forKey: owner)
    }
    if manualUnreadHold != focusedSession {
      manualUnreadHold = nil
    }
    readFocusedSessionIfNeeded()
  }

  public var openSessions: Set<SessionAttentionFocus> {
    Set(openByOwner.values)
  }

  public func updateOpenSession(owner: ObjectIdentifier, session: SessionAttentionFocus?) {
    openByOwner[owner] = session
  }

  public func setApplicationActive(_ active: Bool) {
    applicationActive = active
    if active {
      readFocusedSessionIfNeeded()
    }
  }

  private func readFocusedSessionIfNeeded() {
    guard applicationActive, let focused = focusedSession,
      focused != manualUnreadHold,
      let session = projectList.sessions.first(where: {
        $0.serverId == focused.serverId && $0.id == focused.sessionId
      }),
      SessionAttentionSummary(session).hasUnseenAttention
    else { return }
    projectList.markSessionRead(
      focused.sessionId,
      serverId: focused.serverId,
      throughSequence: session.latestAttentionSequence
    )
    notificationDelivery?.clearNotifications(for: focused.sessionId)
  }

  private func isFocused(_ transition: SessionAttentionTransition) -> Bool {
    guard applicationActive, let focused = focusedSession else { return false }
    return focused.serverId == transition.serverId
      && focused.sessionId == transition.sessionId
  }

  private func handle(_ transition: SessionAttentionTransition) {
    if transition.clearsDeliveredNotifications {
      notificationDelivery?.clearNotifications(for: transition.sessionId)
    }
    if isFocused(transition) {
      if transition.origin == .localMarkUnread {
        manualUnreadHold = focusedSession
        return
      }
      if transition.origin == .liveEvent,
        let old = transition.old,
        transition.new.latestAttentionSequence > old.latestAttentionSequence
      {
        manualUnreadHold = nil
      }
      readFocusedSessionIfNeeded()
      return
    }
    guard transition.origin == .liveEvent,
      let kind = SessionAttentionTransition.notificationEdge(
        old: transition.old,
        new: transition.new
      )
    else { return }
    guard announces(transition, kind: kind) else { return }
    notificationDelivery?.deliver(
      ChatAttentionEvent(
        sessionId: transition.sessionId,
        serverId: transition.serverId,
        sessionTitle: transition.new.title,
        kind: kind,
        botMessage: kind == .finished ? transition.new.latestBotMessage : nil
      ))
  }

  private func announces(_ transition: SessionAttentionTransition, kind: ChatAttentionKind) -> Bool {
    let session = SessionAttentionFocus(serverId: transition.serverId, sessionId: transition.sessionId)
    let announces = announcementFilter?(session, openSessions) ?? true
    let decision = announces ? "announce" : "mute"
    Log.notifications.info(
      "\(decision, privacy: .public) \(kind.rawValue, privacy: .public) for session \(session.sessionId.uuidString, privacy: .public)"
    )
    return announces
  }
}
