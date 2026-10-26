import CodevisorCore
import SwiftUI

struct BotConversationHeader: View {
  static let avatarSize: CGFloat = 44
  static let height: CGFloat = 74

  let bot: Bot
  let onOpenDetails: (() -> Void)?

  var body: some View {
    VStack(spacing: -8) {
      BotAvatar(botID: bot.id, symbolName: bot.symbolName, size: Self.avatarSize)
        .zIndex(1)
      Button(action: { onOpenDetails?() }) {
        BotConversationHeaderName(name: bot.name)
      }
      .buttonStyle(.plain)
      .disabled(onOpenDetails == nil)
      .accessibilityLabel(bot.name)
      .accessibilityHint("Shows bot details")
    }
    .padding(.top, 6)
    .frame(height: Self.height, alignment: .top)
  }
}
