import SwiftUI
import CodevisorCore
import CodevisorUI

struct ChatSessionLeadingIcon: View {
  let session: ChatSession
  let store: SessionStore?
  var activityColor: Color = .secondary
  var iconSize: CGFloat = 13

  var body: some View {
    Group {
      if store?.hasUnreadError(session) == true {
        ErrorUnreadBadge(color: .red)
      } else if store?.isWaitingOnUser(session) == true {
        ActionRequiredIndicator(color: .red)
      } else if store?.isInProgress(session) == true {
        AgentStatusIndicator(status: .working, activityColor: activityColor)
      } else if let store, store.unreadCount(session) > 0 {
        AgentStatusIndicator(status: .unread)
      } else {
        HarnessIcon(harnessId: session.harnessId, fallbackSymbolName: "bubble.and.pencil", size: iconSize)
      }
    }
    .frame(width: 18)
  }
}
