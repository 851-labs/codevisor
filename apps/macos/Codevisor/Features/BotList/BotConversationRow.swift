import CodevisorCore
import SwiftUI

struct BotConversationRow: View {
  static let avatarSize: CGFloat = 40

  let conversation: BotConversation
  let isSelected: Bool
  let now: Date
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var isHovered = false

  private var isHighlighted: Bool { isSelected && controlActiveState == .key }

  var body: some View {
    HStack(spacing: 6) {
      BotUnreadDot(isVisible: conversation.isUnread && !isSelected)
      BotAvatar(botID: conversation.bot.id, symbolName: conversation.bot.symbolName, size: Self.avatarSize)
      VStack(alignment: .leading, spacing: 2) {
        BotConversationTitleLine(
          name: conversation.bot.name, timestamp: timestamp, isHighlighted: isHighlighted)
        BotConversationPreview(conversation: conversation, isHighlighted: isHighlighted)
      }
    }
    .padding(.vertical, 8)
    .padding(.trailing, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    .background(background)
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private var timestamp: String? {
    conversation.lastActivityAt.map { BotConversationTimestamp.text(for: $0, now: now) }
  }

  private var background: some View {
    RowSelectionStyle.shape.fill(fill)
  }

  private var fill: Color {
    if isHighlighted { return .accentColor }
    return RowSelectionStyle.fill(isSelected: isSelected, isHovered: isHovered)
  }
}
