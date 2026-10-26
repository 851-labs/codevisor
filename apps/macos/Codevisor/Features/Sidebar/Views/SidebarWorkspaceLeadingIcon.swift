import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarWorkspaceLeadingIcon: View {
  let icon: SidebarWorkspaceIcon
  let store: SessionStore?

  var body: some View {
    switch icon {
    case let .chat(session):
      ChatSessionLeadingIcon(
        session: session, store: store, activityColor: .secondary, iconSize: SidebarRowIcon.size
      )
      .foregroundStyle(.secondary)
    case .workingTerminal:
      AgentStatusIndicator(status: .working)
        .frame(width: 18)
    case .workspace:
      Image(systemName: EntitySystemSymbol.workspace)
        .frame(width: 18)
        .foregroundStyle(.secondary)
    }
  }
}
