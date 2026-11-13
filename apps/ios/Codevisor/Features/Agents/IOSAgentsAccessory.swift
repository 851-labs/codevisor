import CodevisorCore
import CodevisorUI
import SwiftUI

struct IOSAgentsAccessory: View {
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
              Text(agent.title.isEmpty ? "Agent" : agent.title)
              if let place = place(of: agent) { Text(place) }
            }
          }
        } label: {
          HStack(spacing: 6) {
            HarnessGlyph(
              harnessId: summary.sharedHarnessId, fallbackSymbolName: "person.2", size: 13)
            Text(summary.title)
              .monospacedDigit()
          }
          .font(.subheadline.weight(.medium))
          .padding(.horizontal, 12)
          .padding(.vertical, 7)
          .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("agents", in: glassNamespace)
        .accessibilityLabel(summary.title)
        .accessibilityHint("Shows the agents this chat started")
        .accessibilityIdentifier("composer.agents")
        Spacer(minLength: 0)
      }
    }
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
