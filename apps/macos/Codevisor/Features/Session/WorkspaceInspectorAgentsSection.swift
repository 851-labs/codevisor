import SwiftUI

struct WorkspaceInspectorAgent: Identifiable {
  let id: UUID
  let details: WorkspaceRowDetails
  let lifecycle: WorkspaceRowLifecycle
  let open: () -> Void

  func closing(with dismiss: @escaping () -> Void) -> WorkspaceInspectorAgent {
    WorkspaceInspectorAgent(id: id, details: details, lifecycle: dismissing(lifecycle, with: dismiss)) {
      open()
      dismiss()
    }
  }

  private func dismissing(
    _ lifecycle: WorkspaceRowLifecycle, with dismiss: @escaping () -> Void
  ) -> WorkspaceRowLifecycle {
    switch lifecycle {
    case let .active(actions): .active(actions.renaming(after: dismiss))
    case let .chat(onArchive):
      .chat {
        dismiss()
        onArchive()
      }
    case .archived: lifecycle
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
