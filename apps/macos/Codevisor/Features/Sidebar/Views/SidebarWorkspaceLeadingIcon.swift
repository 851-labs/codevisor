import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarWorkspaceLeadingIcon: View {
  let icon: SidebarWorkspaceIcon
  let store: SessionStore?
  var status: SidebarRowStatus? = nil
  var color: Color = .secondary
  var statusColor: Color? = nil

  var body: some View {
    if let status, status.replacesLeadingIcon(isUnread: showsUnreadDot) {
      SidebarRowStatusSymbol(status: status, size: SidebarRowIcon.size)
        .frame(width: 18)
    } else {
      iconBody
    }
  }

  private var showsUnreadDot: Bool {
    guard case let .chat(session, isQuiet) = icon, !isQuiet else { return false }
    return (store?.unreadCount(session) ?? session.unreadCount) > 0
  }

  @ViewBuilder
  private var iconBody: some View {
    switch icon {
    case let .chat(session, isQuiet):
      ChatSessionLeadingIcon(
        session: session, store: store, activityColor: color, statusColor: statusColor,
        iconSize: SidebarRowIcon.size, isQuiet: isQuiet
      )
      .foregroundStyle(color)
    case .workingTerminal:
      AgentStatusIndicator(status: .working, activityColor: color)
        .frame(width: 18)
    case .workspace:
      Image(systemName: EntitySystemSymbol.workspace)
        .frame(width: 18)
        .foregroundStyle(color)
    }
  }
}
