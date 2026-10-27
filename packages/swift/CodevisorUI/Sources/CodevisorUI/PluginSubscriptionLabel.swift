import CodevisorCore
import SwiftUI

public struct PluginSubscriptionLabel: View {
  let subscription: ServerPluginEventSubscription
  let chatTitle: String?

  public init(subscription: ServerPluginEventSubscription, chatTitle: String?) {
    self.subscription = subscription
    self.chatTitle = chatTitle
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(subscription.note ?? subscription.explained)
      if subscription.note != nil {
        Text(subscription.explained)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let chatTitle {
        Label(chatTitle, systemImage: "bubble.left")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let pausedReason = subscription.pausedReason {
        Label(pausedReason, systemImage: "pause.circle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }
}
