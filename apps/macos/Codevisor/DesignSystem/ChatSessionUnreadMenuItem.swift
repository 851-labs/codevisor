import CodevisorCore
import SwiftUI

/// The read/unread action shared by chat sidebar rows and pane menus.
struct ChatSessionUnreadMenuItem: View {
  let session: ChatSession
  let store: SessionStore?

  var body: some View {
    Button {
      if isUnread {
        store?.markRead(session)
      } else {
        store?.markUnread(session)
      }
    } label: {
      Label(
        isUnread ? "Mark as read" : "Mark as unread",
        systemImage: isUnread ? "message" : "message.badge"
      )
      .labelStyle(.titleAndIcon)
    }
  }

  private var isUnread: Bool {
    guard let store else { return false }
    return store.unreadCount(session) > 0 || store.hasUnreadError(session)
  }
}
