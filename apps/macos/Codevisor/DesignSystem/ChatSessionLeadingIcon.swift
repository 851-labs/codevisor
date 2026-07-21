import SwiftUI
import CodevisorCore

/// The shared chat identity/status slot used by the sidebar and split headers.
/// Attention states replace the harness icon in the same priority order
/// everywhere the chat is represented.
struct ChatSessionLeadingIcon: View {
    let session: ChatSession
    let store: SessionStore?

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if store?.hasUnreadError(session) == true {
                ErrorUnreadBadge(color: theme.statusError)
            } else if store?.isWaitingOnUser(session) == true {
                ActionRequiredIndicator(color: theme.statusError)
            } else if store?.isRunning(session) == true {
                AgentActivityIndicator()
            } else if let store, store.unreadCount(session) > 0 {
                UnreadBadge(color: notificationColor)
            } else {
                HarnessIcon(harnessId: session.harnessId, fallbackSymbolName: "bubble.left.fill")
            }
        }
        .frame(width: 18)
    }

    private var notificationColor: Color {
        theme.isSystem ? .blue : theme.accent
    }
}
