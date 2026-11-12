import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotConversationRow: View {
  static let avatarSize: CGFloat = 40

  let conversation: BotConversation
  let isSelected: Bool
  var status: SidebarRowStatus? = nil
  var showsStatusLabel = false

  var body: some View {
    HoverableRow(isSelected: isSelected) { _ in
      HStack(spacing: 6) {
        BotUnreadDot(isVisible: conversation.isUnread && !isSelected)
        avatar
        VStack(alignment: .leading, spacing: 2) {
          BotConversationTitleLine(name: conversation.bot.name, status: status, showsStatusLabel: showsStatusLabel)
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

  @ViewBuilder
  private var avatar: some View {
    let bot = conversation.bot
    if let mascot = bot.mascot {
      BotMascotFigure(bot: bot, mascot: mascot, slot: Self.avatarSize)
    } else {
      BotSymbolAvatar(symbolName: bot.symbolName, size: Self.avatarSize)
    }
  }
}
