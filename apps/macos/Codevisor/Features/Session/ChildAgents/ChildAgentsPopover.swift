import SwiftUI

struct ChildAgentsPopover: View {
  let agents: [WorkspaceInspectorAgent]
  let store: SessionStore
  let dismiss: () -> Void

  private static let width: CGFloat = 300
  private static let maxListHeight: CGFloat = 360

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Child Agents")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
      ViewThatFits(in: .vertical) {
        rows
        ScrollView { rows }
      }
      .frame(maxHeight: Self.maxListHeight)
      .fixedSize(horizontal: false, vertical: true)
      .background(Color.primary.opacity(0.034))
      .clipShape(.rect(cornerRadius: 10))
    }
    .padding(10)
    .frame(width: Self.width)
  }

  private var rows: some View {
    WorkspaceInspectorCardRows {
      ForEach(agents) { agent in
        WorkspaceInspectorAgentRow(agent: agent.opening(then: dismiss), store: store)
      }
    }
  }
}
