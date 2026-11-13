import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorSubscriptionsSection: View {
  let events: [SubscribedPluginEvent]
  let serverId: String
  let client: any CodevisorServerClienting
  @Binding var isExpanded: Bool
  let onRemove: (SubscribedPluginEvent) async -> Bool

  var body: some View {
    WorkspaceInspectorCard(title: "Automations", isExpanded: $isExpanded) {
      ForEach(events) { event in
        WorkspaceInspectorSubscriptionRow(event: event, serverId: serverId, client: client, onRemove: onRemove)
      }
    }
  }
}

private struct WorkspaceInspectorSubscriptionRow: View {
  let event: SubscribedPluginEvent
  let serverId: String
  let client: any CodevisorServerClienting
  let onRemove: (SubscribedPluginEvent) async -> Bool
  @State private var showsDetails = false

  var body: some View {
    Button {
      showsDetails = true
    } label: {
      WorkspaceInspectorSubscriptionLabel(event: event, serverId: serverId, client: client)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(event.title)
    .accessibilityLabel(event.label)
    .popover(isPresented: $showsDetails, arrowEdge: .leading) {
      WorkspaceInspectorAutomationPopover(event: event) {
        await onRemove(event)
      }
    }
  }
}

private struct WorkspaceInspectorSubscriptionLabel: View {
  let event: SubscribedPluginEvent
  let serverId: String
  let client: any CodevisorServerClienting

  var body: some View {
    Label {
      WorkspaceInspectorSubscriptionTitle(event: event)
        .lineLimit(1)
        .truncationMode(.tail)
    } icon: {
      WorkspaceInspectorSubscriptionIcon(event: event, serverId: serverId, client: client)
        .foregroundStyle(.secondary)
        .frame(width: 20)
    }
  }
}

private struct WorkspaceInspectorSubscriptionIcon: View {
  let event: SubscribedPluginEvent
  let serverId: String
  let client: any CodevisorServerClienting

  var body: some View {
    if let symbolName = event.symbolName {
      Image(systemName: symbolName)
    } else {
      PluginIconView(pluginId: event.plugin, client: client, cacheNamespace: serverId, side: 16)
    }
  }
}

private struct WorkspaceInspectorSubscriptionTitle: View {
  let event: SubscribedPluginEvent

  var body: some View {
    if let firesAt = event.firesAt {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(SubscriptionCountdown.text(until: firesAt, now: context.date))
      }
    } else {
      Text(event.title)
    }
  }
}
