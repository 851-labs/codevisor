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
        HomeSidebarBotConversationTitle(name: bot.bot.name, showsChevron: showsChevron)
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
      BotMascotFigure(mascot: mascot, serverId: bot.serverId, slot: avatarSize, motion: motion)
    } else {
      BotSymbolAvatar(symbolName: bot.symbolName, size: avatarSize)
    }
  }

  private var motion: BotMascotMotion {
    if bot.conversation.activity == .working {
      .working
    } else if isOpen {
      .idle
    } else {
      .still
    }
  }
}
