import CodevisorUI
import SwiftUI

struct ChildAgentsPill: View {
  let agents: [WorkspaceInspectorAgent]
  let store: SessionStore
  let glassNamespace: Namespace.ID
  @State private var isShowingAll = false

  private static let shownLimits = [3, 2, 1]

  var body: some View {
    Button {
      isShowingAll.toggle()
    } label: {
      ViewThatFits(in: .horizontal) {
        ForEach(Self.shownLimits, id: \.self) { limit in
          ChildAgentsPillRow(overflow: ChildAgentsOverflow(agents, limit: limit), store: store)
        }
      }
    }
    .buttonStyle(ChildAgentsPillButtonStyle())
    .composerGlassSurface(shape: Capsule(), id: .childAgents, in: glassNamespace)
    .popover(isPresented: $isShowingAll, arrowEdge: .top) {
      ChildAgentsPopover(agents: agents, store: store) { isShowingAll = false }
    }
    .help("Show active child agents")
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    let names = agents.map { SidebarWorkspaceRowLabel.title(for: $0.name) }
    let noun = agents.count == 1 ? "child agent" : "child agents"
    return "\(agents.count) active \(noun): \(names.joined(separator: ", "))"
  }
}

private struct ChildAgentsPillRow: View {
  let overflow: ChildAgentsOverflow<WorkspaceInspectorAgent>
  let store: SessionStore

  var body: some View {
    HStack(spacing: 12) {
      ForEach(overflow.shown) { agent in
        ChildAgentsPillChip(agent: agent, store: store)
      }
      if overflow.hiddenCount > 0 {
        ChildAgentsPillOverflowChip(count: overflow.hiddenCount)
      }
    }
    .fixedSize()
  }
}

private struct ChildAgentsPillChip: View {
  let agent: WorkspaceInspectorAgent
  let store: SessionStore

  private static let maxTitleWidth: CGFloat = 170

  var body: some View {
    HStack(spacing: 4) {
      SidebarWorkspaceLeadingIcon(icon: agent.icon, store: store)
      Text(SidebarWorkspaceRowLabel.title(for: agent.name))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct ChildAgentsPillOverflowChip: View {
  let count: Int

  var body: some View {
    Text("+\(count)")
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(Color.primary.opacity(0.06), in: Capsule())
  }
}

private struct ChildAgentsPillButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    ChildAgentsPillButtonBody(configuration: configuration)
  }
}

private struct ChildAgentsPillButtonBody: View {
  let configuration: ButtonStyleConfiguration
  @State private var isHovered = false

  var body: some View {
    configuration.label
      .font(.system(size: 12))
      .padding(.leading, 6)
      .padding(.trailing, 10)
      .frame(height: 28)
      .background(Capsule().fill(isHovered ? Color.primary.opacity(0.06) : .clear))
      .contentShape(Capsule())
      .contentShape(.focusEffect, Capsule())
      .onHover { isHovered = $0 }
      .opacity(configuration.isPressed ? 0.8 : 1)
  }
}
