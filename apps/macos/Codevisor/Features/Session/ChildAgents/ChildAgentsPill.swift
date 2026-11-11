import CodevisorUI
import SwiftUI

struct ChildAgentsPill: View {
  let content: ChildAgentsPillContent
  let glassNamespace: Namespace.ID
  @State private var isShowingChildren = false

  var body: some View {
    Button {
      isShowingChildren.toggle()
    } label: {
      ChildAgentsPillLabel(summary: content.summary)
    }
    .buttonStyle(ChildAgentsPillButtonStyle())
    .composerGlassSurface(shape: Capsule(), id: .childAgents, in: glassNamespace)
    .popover(isPresented: $isShowingChildren, arrowEdge: .top) {
      ChildAgentsPopover(agents: content.agents, store: content.store) { isShowingChildren = false }
    }
    .help("Show child agents")
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    let summary = content.summary
    guard summary.isWorking else { return summary.title }
    return "\(summary.title), \(summary.workingCount) working"
  }
}

private struct ChildAgentsPillLabel: View {
  let summary: ChildAgentsSummary

  var body: some View {
    HStack(spacing: 4) {
      glyph
        .frame(width: 18)
      Text(summary.title)
        .monospacedDigit()
    }
    .fixedSize()
  }

  @ViewBuilder
  private var glyph: some View {
    if summary.isWorking {
      AgentActivityIndicator(color: .secondary)
    } else if let harnessId = summary.sharedHarnessId {
      HarnessIcon(harnessId: harnessId, fallbackSymbolName: "bubble.and.pencil", size: SidebarRowIcon.size)
        .foregroundStyle(.secondary)
    } else {
      Circle()
        .fill(.secondary)
        .frame(width: Self.dotDiameter, height: Self.dotDiameter)
    }
  }

  private static let dotDiameter: CGFloat = 6
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
