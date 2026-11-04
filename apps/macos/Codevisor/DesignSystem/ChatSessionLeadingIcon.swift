import SwiftUI
import CodevisorCore
import CodevisorUI

struct ChatSessionLeadingIcon: View {
  let session: ChatSession
  let store: SessionStore?
  var activityColor: Color = .secondary
  var statusColor: Color? = nil
  var iconSize: CGFloat = 13
  var isQuiet = false

  var body: some View {
    Group {
      if !isQuiet, store?.hasUnreadError(session) == true {
        ErrorUnreadBadge(color: statusColor ?? .red)
      } else if !isQuiet, store?.isWaitingOnUser(session) == true {
        ActionRequiredIndicator(color: statusColor ?? .red)
      } else if store?.isInProgress(session) == true {
        AgentStatusIndicator(status: .working, activityColor: activityColor)
      } else if !isQuiet, let store, store.unreadCount(session) > 0 {
        UnreadBadge(color: statusColor ?? .blue)
      } else {
        HarnessIcon(harnessId: session.harnessId, fallbackSymbolName: "bubble.and.pencil", size: iconSize)
      }
    }
    .frame(width: 18)
  }
}
