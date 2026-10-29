import SwiftUI

struct WorkspaceInspectorAgent: Identifiable {
  let id: UUID
  let name: String
  let subtitle: String?
  let icon: SidebarWorkspaceIcon
  let open: () -> Void
}

struct WorkspaceInspectorAgentsSection: View {
  let agents: [WorkspaceInspectorAgent]
  let store: SessionStore
  @Binding var isExpanded: Bool

  var body: some View {
    WorkspaceInspectorCard(title: "Agents", isExpanded: $isExpanded) {
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
      SidebarWorkspaceRowLabel(name: agent.name, subtitle: agent.subtitle, icon: agent.icon, store: store)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Open \(title)")
  }
}
