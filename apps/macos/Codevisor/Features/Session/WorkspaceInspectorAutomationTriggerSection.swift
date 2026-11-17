import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorAutomationTriggerSection: View {
  let event: SubscribedPluginEvent
  let serverId: String
  let client: any CodevisorServerClienting

  var body: some View {
    if event.isSchedule {
      WorkspaceInspectorAutomationScheduleSection(event: event)
    } else {
      WorkspaceInspectorAutomationPluginTriggerSection(event: event, serverId: serverId, client: client)
    }
  }
}

private struct WorkspaceInspectorAutomationScheduleSection: View {
  let event: SubscribedPluginEvent

  var body: some View {
    Section("Schedule") {
      WorkspaceInspectorAutomationTimedText(title: "Schedule", text: event.explained, firesAt: event.firesAt)
    }
  }
}

private struct WorkspaceInspectorAutomationPluginTriggerSection: View {
  let event: SubscribedPluginEvent
  let serverId: String
  let client: any CodevisorServerClienting

  var body: some View {
    Section("Trigger") {
      LabeledContent("Event") {
        WorkspaceInspectorAutomationSource(event: event, serverId: serverId, client: client)
      }
      WorkspaceInspectorAutomationCondition(condition: event.explained, firesAt: event.firesAt)
    }
  }
}

private struct WorkspaceInspectorAutomationCondition: View {
  let condition: String
  let firesAt: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("When")
        .accessibilityHidden(true)
      WorkspaceInspectorAutomationTimedText(title: "When", text: condition, firesAt: firesAt)
        .foregroundStyle(.secondary)
    }
  }
}

private struct WorkspaceInspectorAutomationSource: View {
  let event: SubscribedPluginEvent
  let serverId: String
  let client: any CodevisorServerClienting

  var body: some View {
    Label {
      Text(event.label)
    } icon: {
      WorkspaceInspectorSubscriptionIcon(event: event, serverId: serverId, client: client)
    }
  }
}

private struct WorkspaceInspectorAutomationTimedText: View {
  let title: String
  let text: String
  let firesAt: Date?

  var body: some View {
    if let firesAt {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        WorkspaceInspectorAutomationCountdownLine(title: title, text: text, firesAt: firesAt, now: context.date)
      }
    } else {
      Text(text)
        .textSelection(.enabled)
        .accessibilityLabel(title)
        .accessibilityValue(text)
    }
  }
}

private struct WorkspaceInspectorAutomationCountdownLine: View {
  let title: String
  let text: String
  let firesAt: Date
  let now: Date

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue)
      Text(SubscriptionCountdown.text(until: firesAt, now: now))
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityHidden(true)
    }
  }

  private var spokenValue: String {
    "\(text), \(SubscriptionCountdown.spokenText(until: firesAt, now: now))"
  }
}
