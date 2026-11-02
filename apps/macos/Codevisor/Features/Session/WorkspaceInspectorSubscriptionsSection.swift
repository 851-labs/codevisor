import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorSubscriptionsSection: View {
  let events: [SubscribedPluginEvent]
  let serverId: String
  let client: any CodevisorServerClienting
  @Binding var isExpanded: Bool

  var body: some View {
    WorkspaceInspectorCard(title: "Subscriptions", isExpanded: $isExpanded) {
      ForEach(events) { event in
        WorkspaceInspectorSubscriptionRow(event: event, serverId: serverId, client: client)
      }
    }
  }
}

private struct WorkspaceInspectorSubscriptionRow: View {
  let event: SubscribedPluginEvent
  let serverId: String
  let client: any CodevisorServerClienting

  var body: some View {
    Label {
      Text(event.label)
        .lineLimit(1)
        .truncationMode(.tail)
    } icon: {
      PluginIconView(pluginId: event.plugin, client: client, cacheNamespace: serverId, side: 16)
        .foregroundStyle(.secondary)
        .frame(width: 20)
    }
    .help(event.label)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(event.label)
  }
}
