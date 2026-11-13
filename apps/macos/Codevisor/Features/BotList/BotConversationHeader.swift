import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotConversationHeader: View {
  static let avatarSize: CGFloat = 44
  static let height: CGFloat = 74
  static let overlap = BotHeaderAvatarMetrics.overlap

  let bot: Bot
  let onOpenDetails: (() -> Void)?

  var body: some View {
    Button(action: { onOpenDetails?() }) {
      VStack(spacing: -Self.overlap) {
        BotAvatar(bot: bot, size: Self.avatarSize)
          .botHeaderAvatarShadow()
        BotConversationHeaderName(
          name: bot.name,
          shape: BotConversationHeaderNameShape(avatarSize: Self.avatarSize, overlap: Self.overlap)
        )
      }
    }
    .buttonStyle(.plain)
    .allowsHitTesting(opensDetails)
    .accessibilityLabel(bot.name)
    .accessibilityHint(opensDetails ? "Edit bot" : "")
    .padding(.top, 4)
    .frame(height: Self.height, alignment: .top)
  }

  private var opensDetails: Bool {
    onOpenDetails != nil
  }
}
