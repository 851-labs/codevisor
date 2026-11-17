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
      Text(event.explained)
        .textSelection(.enabled)
        .accessibilityLabel("Schedule")
        .accessibilityValue(event.explained)
      WorkspaceInspectorAutomationNextRun(event: event)
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
      WorkspaceInspectorAutomationCondition(condition: event.explained)
      WorkspaceInspectorAutomationNextRun(event: event)
    }
  }
}

private struct WorkspaceInspectorAutomationCondition: View {
  let condition: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("When")
        .accessibilityHidden(true)
      Text(condition)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityLabel("When")
        .accessibilityValue(condition)
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

private struct WorkspaceInspectorAutomationNextRun: View {
  let event: SubscribedPluginEvent

  var body: some View {
    if let firesAt = event.firesAt {
      LabeledContent("Next run") {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(SubscriptionCountdown.text(until: firesAt, now: context.date))
            .lineLimit(1)
        }
      }
      .help(dateTooltip(for: firesAt))
    }
  }

  private var scheduleShowsDate: Bool {
    event.isSchedule && event.once
  }

  private func dateTooltip(for firesAt: Date) -> String {
    guard !scheduleShowsDate else { return "" }

    return firesAt.formatted(date: .abbreviated, time: .shortened)
  }
}
