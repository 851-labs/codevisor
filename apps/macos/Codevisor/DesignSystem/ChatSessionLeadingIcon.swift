import SwiftUI
import CodevisorCore
import CodevisorUI

/// The shared chat identity/status slot used by the sidebar and split headers.
/// Attention states replace the harness icon in the same priority order
/// everywhere the chat is represented.
struct ChatSessionLeadingIcon: View {
    let session: ChatSession
    let store: SessionStore?

    @Environment(\.theme) private var theme

    var body: some View {
        // This precedence (error → waiting → in progress → unread) is
        // mirrored by the sidebar's `sessionPriority(for:)` classification.
        // Keep the two in sync: if they diverge, a row can sort by a state
        // its icon doesn't show, and merely opening the chat reorders the
        // sidebar with no visible state change.
        Group {
            if store?.hasUnreadError(session) == true {
                ErrorUnreadBadge(color: theme.statusError)
            } else if store?.isWaitingOnUser(session) == true {
                ActionRequiredIndicator(color: theme.statusError)
            } else if store?.isInProgress(session) == true {
                AgentActivityIndicator()
            } else if let store, store.unreadCount(session) > 0 {
                UnreadBadge(color: notificationColor)
            } else {
                HarnessIcon(harnessId: session.harnessId, fallbackSymbolName: "bubble.and.pencil")
            }
        }
        .frame(width: 18)
    }

    private var notificationColor: Color {
        theme.isSystem ? .blue : theme.accent
    }
}
