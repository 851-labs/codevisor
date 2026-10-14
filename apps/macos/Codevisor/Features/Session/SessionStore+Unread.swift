import Foundation
import Observation
import CodevisorCore
import ACPKit

extension SessionStore {
  func unreadCount(_ session: ChatSession) -> Int {
    session.unreadCount
  }

  func hasUnreadError(_ session: ChatSession) -> Bool {
    session.hasUnreadError
  }

  func markUnread(_ session: ChatSession) {
    environment.projectList.markSessionUnread(session.id, serverId: session.serverId)
  }

  func markRead(_ session: ChatSession) {
    environment.projectList.markSessionRead(session.id, serverId: session.serverId)
  }

  func markOpened(_ sessionId: UUID, serverId: String) {
    let key = SessionKey(serverId: serverId, sessionId: sessionId)
    openSessionKey = key
  }

  func clearOpenSession() {
    openSessionKey = nil
    navigationWorkspaceId = nil
  }

  func setWindowFocused(_ focused: Bool) {
    isWindowFocused = focused
    publishFocus()
  }

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

  func noteTurnEnded() {
    activityRevision &+= 1
  }
}
