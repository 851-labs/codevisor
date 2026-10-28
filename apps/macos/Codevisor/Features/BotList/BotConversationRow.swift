import CodevisorCore
import SwiftUI

struct BotConversationRow: View {
  static let avatarSize: CGFloat = 40

  let conversation: BotConversation
  let isSelected: Bool
  let now: Date

  var body: some View {
    HoverableRow(isSelected: isSelected) { _ in
      HStack(spacing: 6) {
        BotUnreadDot(isVisible: conversation.isUnread && !isSelected)
        BotAvatar(botID: conversation.bot.id, symbolName: conversation.bot.symbolName, size: Self.avatarSize)
        VStack(alignment: .leading, spacing: 2) {
          BotConversationTitleLine(name: conversation.bot.name, timestamp: timestamp)
          BotConversationPreview(conversation: conversation)
        }
      }
      .padding(.vertical, 15)
      .padding(.trailing, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private var timestamp: String? {
    conversation.lastActivityAt.map { BotConversationTimestamp.text(for: $0, now: now) }
  }
}
