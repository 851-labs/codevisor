import CodevisorCore
import SwiftUI

struct BotConversationHeader: View {
  static let avatarSize: CGFloat = 44
  static let height: CGFloat = 74

  let bot: Bot
  let onOpenDetails: (() -> Void)?

  var body: some View {
    Button(action: { onOpenDetails?() }) {
      VStack(spacing: -8) {
        BotAvatar(bot: bot, size: Self.avatarSize)
          .zIndex(1)
        BotConversationHeaderName(name: bot.name)
      }
    }
    .buttonStyle(.plain)
    .disabled(onOpenDetails == nil)
    .accessibilityLabel(bot.name)
    .accessibilityHint("Edit bot")
    .padding(.top, 6)
    .frame(height: Self.height, alignment: .top)
  }
}
