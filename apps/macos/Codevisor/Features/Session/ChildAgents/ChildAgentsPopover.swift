import SwiftUI

struct ChildAgentsPopover: View {
  let agents: [WorkspaceInspectorAgent]
  let store: SessionStore
  let dismiss: () -> Void

  private static let width: CGFloat = 300
  private static let maxHeight: CGFloat = 380
  private static let padding: CGFloat = 10

  var body: some View {
    ViewThatFits(in: .vertical) {
      card
      ScrollView { card }
    }
    .frame(maxHeight: Self.maxHeight)
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: Self.width)
  }

  private var card: some View {
    WorkspaceInspectorCardRows {
      ForEach(agents) { agent in
        WorkspaceInspectorAgentRow(
          agent: agent.closing(with: dismiss),
          store: store,
          focusShape: WorkspaceInspectorCardShape.row(for: agent, in: agents)
        )
      }
    }
    .background(Color.primary.opacity(0.034), in: WorkspaceInspectorCardShape.card)
    .padding(Self.padding)
  }
}
