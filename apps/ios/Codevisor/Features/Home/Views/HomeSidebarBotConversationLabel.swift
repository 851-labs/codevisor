import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarBotConversationLabel: View {
  @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 44

  let bot: HomeSidebarBot
  let isOpen: Bool
  let showsChevron: Bool

  var body: some View {
    HStack(spacing: 12) {
      HStack(spacing: 6) {
        HomeSidebarUnreadDot(isVisible: bot.conversation.isUnread && !isOpen)
        avatar
      }
      VStack(alignment: .leading, spacing: 2) {
        HomeSidebarBotConversationTitle(name: bot.bot.name, status: bot.rowStatus, showsChevron: showsChevron)
        HomeSidebarBotConversationPreview(conversation: bot.conversation)
      }
      .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var avatar: some View {
    let bot = bot.bot
    if let mascot = bot.mascot {
      BotMascotFigure(bot: bot, mascot: mascot, slot: avatarSize)
    } else {
      BotSymbolAvatar(symbolName: bot.symbolName, size: avatarSize)
    }
  }
}
