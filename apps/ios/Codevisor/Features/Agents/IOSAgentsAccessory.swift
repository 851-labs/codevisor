import CodevisorCore
import CodevisorUI
import SwiftUI

struct IOSAgentsAccessory: View {
  static let rowHeight = Typography.minimumInteractiveTargetSize
  private static let dotDiameter: CGFloat = 6

  let agents: [ChatSession]
  let glassNamespace: Namespace.ID
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.openChat) private var openChat
  @State private var isPresentingAgents = false

  private var summary: ChildAgentsSummary? {
    let statuses = HomeSidebarStatusSource(environment: environment)
    return ChildAgentsSummary(agents, isWorking: statuses.isWorking, harnessId: \.harnessId)
  }

  var body: some View {
    if let summary {
      HStack {
        Button {
          isPresentingAgents = true
        } label: {
          label(summary)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .glassEffectID("agents", in: glassNamespace)
        .accessibilityLabel(accessibilityLabel(summary))
        .accessibilityHint("Shows the agents this chat started")
        .accessibilityIdentifier("composer.agents")
        .popover(isPresented: $isPresentingAgents) {
          IOSAgentsSheet(agents: agents) { agent in
            Task { await openChat?(agent) }
          }
          .frame(idealWidth: 400, idealHeight: 480)
        }
        Spacer(minLength: 0)
      }
      .frame(height: Self.rowHeight)
    }
  }

  private func label(_ summary: ChildAgentsSummary) -> some View {
    HStack(spacing: 4) {
      glyph(summary)
        .frame(width: 18)
      Text(summary.title)
        .monospacedDigit()
    }
    .font(.system(size: 13, weight: .medium))
    .foregroundStyle(.primary)
  }

  @ViewBuilder
  private func glyph(_ summary: ChildAgentsSummary) -> some View {
    if summary.isWorking {
      AgentActivityIndicator(color: .secondary)
    } else if let harnessId = summary.sharedHarnessId {
      HarnessGlyph(harnessId: harnessId, fallbackSymbolName: "bubble.and.pencil", size: 13)
        .foregroundStyle(.secondary)
    } else {
      Circle()
        .fill(.secondary)
        .frame(width: Self.dotDiameter, height: Self.dotDiameter)
    }
  }

  private func accessibilityLabel(_ summary: ChildAgentsSummary) -> String {
    guard summary.isWorking else { return summary.title }
    return "\(summary.title), \(summary.workingCount) working"
  }
}
