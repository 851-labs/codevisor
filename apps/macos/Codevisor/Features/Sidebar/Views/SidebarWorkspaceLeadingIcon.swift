import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarWorkspaceLeadingIcon: View {
  let icon: SidebarWorkspaceIcon
  let store: SessionStore?
  var color: Color = .secondary
  var statusColor: Color? = nil

  var body: some View {
    switch icon {
    case let .chat(session):
      ChatSessionLeadingIcon(
        session: session, store: store, activityColor: color, statusColor: statusColor,
        iconSize: SidebarRowIcon.size
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
