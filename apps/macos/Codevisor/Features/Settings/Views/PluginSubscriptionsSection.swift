import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginSubscriptionsSection: View {
  let model: PluginSubscriptionsModel
  let chatTitle: (String) -> String?

  var body: some View {
    if !model.subscriptions.isEmpty {
      PluginListDisclosure("Subscriptions", count: model.subscriptions.count, message: model.errorMessage) {
        ForEach(model.subscriptions) { subscription in
          HStack {
            PluginSubscriptionLabel(subscription: subscription, chatTitle: chatTitle(subscription.sessionId))
            Spacer()
            Button("Remove", systemImage: "minus.circle") { Task { await model.remove(subscription) } }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .help("Remove Subscription")
          }
          .contextMenu {
            Button("Remove Subscription", role: .destructive) { Task { await model.remove(subscription) } }
          }
        }
      }
    }
  }
}
