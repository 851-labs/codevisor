import SwiftUI

struct WorkspaceInspectorAgentRow: View {
  let agent: WorkspaceInspectorAgent
  let store: SessionStore
  let focusShape: UnevenRoundedRectangle
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var isHovered = false

  var body: some View {
    WorkspaceRow(
      details: agent.details, store: store, lifecycle: .active(agent.actions), style: .card(focusShape: focusShape),
      isHovered: isHovered && controlActiveState == .key, onActivate: agent.open
    )
    .onHover { isHovered = $0 }
    .containerValue(\.fillsWorkspaceInspectorCardRow, true)
  }
}
