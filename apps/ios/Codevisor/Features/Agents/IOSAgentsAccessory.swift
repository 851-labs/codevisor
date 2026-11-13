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

  private var summary: ChildAgentsSummary? {
    ChildAgentsSummary(agents, isWorking: { $0.sidebarState == .inProgress }, harnessId: \.harnessId)
  }

  var body: some View {
    if let summary {
      HStack {
        Menu {
          ForEach(agents) { agent in
            Button {
              Task { await openChat?(agent) }
            } label: {
              Label {
                Text(agent.title.isEmpty ? "Agent" : agent.title)
              } icon: {
                HarnessGlyph(harnessId: agent.harnessId, fallbackSymbolName: "bubble.and.pencil")
              }
              if let place = place(of: agent) { Text(place) }
            }
          }
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

  private func place(of agent: ChatSession) -> String? {
    let machine = environment.machines.machine(for: agent.serverId)?.name
    let project = environment.projectList.projects.first {
      $0.serverId == agent.serverId && $0.id == agent.projectId
    }?.name
    let parts = [project, machine].compactMap(\.self)
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
