import CodevisorCore
import SwiftUI

struct BotConversationHeader: View {
  static let barHeight: CGFloat = 56

  let bot: Bot
  let onOpenDetails: () -> Void
  @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 56

  var body: some View {
    Button(action: onOpenDetails) {
      VStack(spacing: -8) {
        BotAvatar(symbolName: bot.symbolName, size: avatarSize)
          .zIndex(1)
        HStack(spacing: 3) {
          Text(bot.name)
            .font(.headline)
            .lineLimit(1)
          Image(systemName: "chevron.forward")
            .font(.footnote.weight(.bold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .capsule)
      }
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(bot.name)
    .accessibilityHint("Shows bot details")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("bot.header")
  }
}

extension EnvironmentValues {
  @Entry var hostedBotHeaderWindowBottom: CGFloat = 0
}
