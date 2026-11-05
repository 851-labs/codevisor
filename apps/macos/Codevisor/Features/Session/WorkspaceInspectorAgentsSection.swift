import CodevisorClient
import SwiftUI

struct WorkspaceInspectorAgent: Identifiable {
  let id: UUID
  let name: String
  let subtitle: String?
  let icon: SidebarWorkspaceIcon
  let pullRequest: ServerGitPullRequest?
  let machine: SidebarRowMachine?
  let open: () -> Void

  func opening(then action: @escaping () -> Void) -> WorkspaceInspectorAgent {
    WorkspaceInspectorAgent(
      id: id, name: name, subtitle: subtitle, icon: icon, pullRequest: pullRequest, machine: machine
    ) {
      open()
      action()
    }
  }
}

struct WorkspaceInspectorAgentsSection: View {
  let title: String
  let agents: [WorkspaceInspectorAgent]
  let store: SessionStore
  @Binding var isExpanded: Bool

  var body: some View {
    WorkspaceInspectorCard(title: title, isExpanded: $isExpanded) {
      ForEach(agents) { agent in
        WorkspaceInspectorAgentRow(agent: agent, store: store)
      }
    }
  }
}
