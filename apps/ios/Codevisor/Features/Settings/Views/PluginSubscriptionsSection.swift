import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginSubscriptionsSection: View {
  let model: PluginSubscriptionsModel
  let chatTitle: (String) -> String?

  var body: some View {
    if !model.subscriptions.isEmpty {
      Section {
        ForEach(model.subscriptions) { subscription in
          PluginSubscriptionLabel(subscription: subscription, chatTitle: chatTitle(subscription.sessionId))
            .swipeActions {
              Button("Remove", role: .destructive) { Task { await model.remove(subscription) } }
            }
        }
      } header: {
        Text("Subscriptions")
      } footer: {
        if let errorMessage = model.errorMessage {
          Text(errorMessage).foregroundStyle(.red)
        }
      }
    }
  }
}
