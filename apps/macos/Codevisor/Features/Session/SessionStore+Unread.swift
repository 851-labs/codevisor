import Foundation
import Observation
import CodevisorCore
import ACPKit

// MARK: - Unread

extension SessionStore {
  /// Finished-and-not-yet-acknowledged turns — the sidebar badge count.
  func unreadCount(_ session: ChatSession) -> Int {
    session.unreadCount
  }

  func hasUnreadError(_ session: ChatSession) -> Bool {
    session.hasUnreadError
  }

  /// Manually flags a session as unread (sidebar context menu). Keeps any
  /// existing turn-finish count rather than resetting it to 1.
  func markUnread(_ session: ChatSession) {
    environment.projectList.markSessionUnread(session.id, serverId: session.serverId)
  }

  /// Manually clears a session's unread badge (sidebar context menu) without
  /// making it the on-screen session. Banner clearing rides the resulting
  /// read transition through the attention coordinator.
  func markRead(_ session: ChatSession) {
    environment.projectList.markSessionRead(session.id, serverId: session.serverId)
  }

  /// Tracks the selected session so its live controller stays in the cache.
  func markOpened(_ sessionId: UUID, serverId: String) {
    let key = SessionKey(serverId: serverId, sessionId: sessionId)
    openSessionKey = key
  }

  /// Called when navigation leaves the session detail (new chat, nothing
  /// selected), so finished turns start counting as unread again.
  func clearOpenSession() {
    openSessionKey = nil
    navigationWorkspaceId = nil
  }

  func setWindowFocused(_ focused: Bool) {
    isWindowFocused = focused
    publishFocus()
  }

  /// Publishes the chat pane facing the user in this window. Nil when a
  /// non-chat pane (terminal, new tab) is selected. Closing or deactivating
  /// the window publishes nil via `setWindowFocused` — resign-key always
  /// fires before a window goes away.
  func setFocusedChat(
    _ sessionId: UUID?, serverId: String, sourceId: UUID, workspaceId: UUID, isVisible: Bool
  ) {
    attentionFocus.update(
      sourceId: sourceId,
      workspaceId: workspaceId,
      isVisible: isVisible,
      session: sessionId.map { SessionAttentionFocus(serverId: serverId, sessionId: $0) }
    )
    publishFocus()
  }

  /// An outgoing container releases only its own focus publication.
  func clearFocusedChat(sourceId: UUID) {
    attentionFocus.clear(sourceId: sourceId)
    publishFocus()
  }

  func publishFocus() {
    environment.attentionCoordinator.updateFocus(
      owner: ObjectIdentifier(self),
      session: isWindowFocused ? attentionFocus.session : nil
    )
  }

  /// Notifications and unread state are handled by the server-side attention
  /// projection + `SessionAttentionCoordinator`; a finished turn here only
  /// invalidates aggregate-activity observers.
  func noteTurnEnded() {
    activityRevision &+= 1
  }
}
