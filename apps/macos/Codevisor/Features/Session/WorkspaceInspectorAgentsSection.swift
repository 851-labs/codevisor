import SwiftUI

struct WorkspaceInspectorAgent: Identifiable {
  let id: UUID
  let details: WorkspaceRowDetails
  let actions: WorkspaceRowActions
  let open: () -> Void

  func closing(with dismiss: @escaping () -> Void) -> WorkspaceInspectorAgent {
    WorkspaceInspectorAgent(id: id, details: details, actions: actions.renaming(after: dismiss)) {
      open()
      dismiss()
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
        WorkspaceInspectorAgentRow(
          agent: agent,
          store: store,
          focusShape: WorkspaceInspectorCardShape.row(for: agent, in: agents)
        )
      }
    }
  }
}
