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

private struct WorkspaceInspectorAgentRow: View {
  let agent: WorkspaceInspectorAgent
  let store: SessionStore

  private var title: String { SidebarWorkspaceRowLabel.title(for: agent.name) }

  var body: some View {
    Button(action: agent.open) {
      HStack(spacing: SidebarWorkspaceRow.trailingSpacing) {
        SidebarWorkspaceRowLabel(name: agent.name, subtitle: agent.subtitle, icon: agent.icon, store: store)
        SidebarWorkspaceRowProperties(pullRequest: agent.pullRequest, machine: agent.machine)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Open \(title)")
  }
}
