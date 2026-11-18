import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAutomationsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  let model: PluginSubscriptionsModel

  var body: some View {
    List {
      Section {
        if model.subscriptions.isEmpty {
          Text("No automations").foregroundStyle(.secondary)
        }
        ForEach(model.subscriptions) { subscription in
          PluginSubscriptionLabel(subscription: subscription, chatTitle: chatTitle(subscription.sessionId))
            .swipeActions {
              Button("Remove", role: .destructive) { Task { await model.remove(subscription) } }
            }
        }
      } footer: {
        if let message = model.errorMessage { Text(message).foregroundStyle(.red) }
      }
    }
    .navigationTitle(PluginListPage.automations.title)
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.load() }
  }

  private func chatTitle(_ sessionId: String) -> String? {
    guard let id = UUID(uuidString: sessionId) else { return nil }
    return environment.projectList.sessions.first { $0.id == id }?.title
  }
}
