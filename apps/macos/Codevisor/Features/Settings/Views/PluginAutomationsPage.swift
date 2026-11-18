import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAutomationsPage: View {
  @Environment(AppEnvironment.self) private var environment
  let model: PluginSubscriptionsModel
  let machineId: String

  var body: some View {
    Form {
      Section {
        if model.subscriptions.isEmpty {
          Text("No automations").foregroundStyle(.secondary)
        }
        ForEach(model.subscriptions) { subscription in
          PluginAutomationRow(subscription: subscription, chatTitle: chatTitle(subscription.sessionId)) {
            Task { await model.remove(subscription) }
          }
        }
      } footer: {
        if let message = model.errorMessage { Text(message).foregroundStyle(.red) }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(PluginListPage.automations.title)
    .task { await model.load() }
  }

  private func chatTitle(_ sessionId: String) -> String? {
    guard let id = UUID(uuidString: sessionId) else { return nil }
    return environment.projectList.session(id, serverId: machineId)?.title
  }
}

private struct PluginAutomationRow: View {
  let subscription: ServerPluginEventSubscription
  let chatTitle: String?
  let remove: () -> Void

  var body: some View {
    HStack {
      PluginSubscriptionLabel(subscription: subscription, chatTitle: chatTitle)
      Spacer()
      Button("Remove", systemImage: "minus.circle", action: remove)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Remove Automation")
    }
    .contextMenu {
      Button("Remove Automation", role: .destructive, action: remove)
    }
  }
}
