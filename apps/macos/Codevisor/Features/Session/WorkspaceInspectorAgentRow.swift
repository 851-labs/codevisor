import SwiftUI

struct WorkspaceInspectorAgentRow: View {
  let agent: WorkspaceInspectorAgent
  let store: SessionStore
  let focusShape: UnevenRoundedRectangle

  private var title: String { SidebarWorkspaceRowLabel.title(for: agent.name) }

  var body: some View {
    Button(action: agent.open) {
      HStack(spacing: SidebarWorkspaceRow.trailingSpacing) {
        SidebarWorkspaceRowLabel(name: agent.name, subtitle: agent.subtitle, icon: agent.icon, store: store)
        SidebarWorkspaceRowProperties(pullRequest: agent.pullRequest, machine: agent.machine)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(WorkspaceInspectorCardShape.rowPadding)
      .contentShape(Rectangle())
      .contentShape(.focusEffect, focusShape)
    }
    .buttonStyle(.plain)
    .containerValue(\.fillsWorkspaceInspectorCardRow, true)
    .accessibilityHint("Open \(title)")
  }
}
