import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorAutomationTriggerSection: View {
  let event: SubscribedPluginEvent
  let serverId: String
  let client: any CodevisorServerClienting

  var body: some View {
    Section {
      if !event.isSchedule {
        LabeledContent("Event") {
          WorkspaceInspectorAutomationSource(event: event, serverId: serverId, client: client)
        }
      }
      WorkspaceInspectorAutomationDetailRow(title: triggerTitle, detail: event.explained)
      if let firesAt = event.firesAt {
        WorkspaceInspectorAutomationNextRun(firesAt: firesAt)
      }
    }
  }

  private var triggerTitle: String {
    event.isSchedule ? "Schedule" : "When"
  }
}

private struct WorkspaceInspectorAutomationDetailRow: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .accessibilityHidden(true)
      Text(detail)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
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
  let firesAt: Date

  var body: some View {
    LabeledContent("Next run") {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        VStack(alignment: .trailing) {
          Text(SubscriptionCountdown.text(until: firesAt, now: context.date))
          Text(firesAt.formatted(date: .abbreviated, time: .shortened))
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
