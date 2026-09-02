import Foundation
import Observation

/// Identifies the chat a platform surface currently has focused.
public struct SessionAttentionFocus: Hashable, Sendable {
  public let serverId: String
  public let sessionId: UUID

  public init(serverId: String, sessionId: UUID) {
    self.serverId = serverId
    self.sessionId = sessionId
  }
}

/// The whole client-side attention policy in one place:
///
/// - **Read = focus.** Platforms publish the chat facing the user (macOS: the
///   selected pane of the active split leaf while its window is key; iOS: the
///   foregrounded chat screen). Focusing a chat with unseen attention marks
///   it read immediately, and it STAYS read while focused — a finish that
///   lands in the focused chat is read instantly with no ping and no sound.
/// - **Notifications are edge-triggered.** A ping fires exactly once on a
///   session's live transition INTO unread or action-required, never while
///   the state persists, never for snapshot catch-ups, and never for the
///   focused chat.
/// - **Banners die with the state.** Any transition back to quiet — read
///   here, read on another device, question answered — clears the session's
///   delivered notifications.
///
/// This replaces the per-window epoch machine (`pendingAttentionErrors`,
/// quiescence gates) that used to live in the macOS `SessionStore`.
@MainActor
@Observable
public final class SessionAttentionCoordinator {
  /// Platform delivery (macOS: `ChatNotificationManager`). Nil on iOS,
  /// which has no notification delivery — focus-read still works.
  @ObservationIgnored public var notificationDelivery: (any ChatNotificationDelivering)?

  private let projectList: ProjectListModel
  /// One entry per publishing surface (a macOS window's `SessionStore`, the
  /// iOS transcript screen). Surfaces publish nil while not user-facing
  /// (window not key, screen prewarming), so at most one entry is live.
  private var focusByOwner: [ObjectIdentifier: SessionAttentionFocus] = [:]
  /// iOS scene-phase gate; macOS folds app activity into window-key
  /// publishing and leaves this true.
  private var applicationActive = true
  /// Manually unreading the chat you are looking at is an explicit "keep
  /// this for later" — focus must not immediately read it back. The hold
  /// lasts until focus moves away or a new finish lands in that chat.
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

  public func setApplicationActive(_ active: Bool) {
    applicationActive = active
    if active {
      readFocusedSessionIfNeeded()
    }
  }

  /// Marks the focused chat read when it has anything unseen. Idempotent:
  /// `markSessionRead` no-ops (locally and network-wise) once caught up, so
  /// repeated focus signals are free.
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
      // A fresh finish overrides a manual-unread hold: there is new
      // content and the user is looking straight at it.
      if transition.origin == .liveEvent,
        let old = transition.old,
        transition.new.latestAttentionSequence > old.latestAttentionSequence
      {
        manualUnreadHold = nil
      }
      // Continuous read-while-focused.
      readFocusedSessionIfNeeded()
      return
    }
    guard transition.origin == .liveEvent,
      let kind = SessionAttentionTransition.notificationEdge(
        old: transition.old,
        new: transition.new
      )
    else { return }
    notificationDelivery?.deliver(
      ChatAttentionEvent(
        sessionId: transition.sessionId,
        serverId: transition.serverId,
        sessionTitle: transition.new.title,
        kind: kind
      ))
  }
}
