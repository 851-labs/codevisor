import SwiftUI

/// Flips between marking a chat unread and clearing an existing unread
/// badge, so the menu never offers the state the row is already in.
struct SidebarUnreadToggleButton: View {
    let isUnread: Bool
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void

    var body: some View {
        if isUnread {
            Button {
                onMarkRead()
            } label: {
                Label("Mark as read", systemImage: "message")
                    .labelStyle(.titleAndIcon)
            }
        } else {
            Button {
                onMarkUnread()
            } label: {
                Label("Mark as unread", systemImage: "message.badge")
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}
