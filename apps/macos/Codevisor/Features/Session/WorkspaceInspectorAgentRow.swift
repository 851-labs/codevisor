import SwiftUI

struct WorkspaceInspectorAgentRow: View {
  let agent: WorkspaceInspectorAgent
  let store: SessionStore
  let focusShape: UnevenRoundedRectangle

  var body: some View {
    WorkspaceRow(
      details: agent.details, store: store, lifecycle: agent.lifecycle, style: .card(focusShape: focusShape),
      onActivate: agent.open
    )
    .containerValue(\.fillsWorkspaceInspectorCardRow, true)
  }
}
