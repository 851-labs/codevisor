import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotConversationChrome: ViewModifier {
  let bot: Bot
  let showsHeader: Bool
  let onEditBot: (Bot) -> Void
  @Environment(WorkspaceActivity.self) private var workspaceActivity: WorkspaceActivity?

  func body(content: Content) -> some View {
    content
      .environment(\.transcriptTopChromeHeight, BotConversationTopBar.height(showsHeader: showsHeader))
      .toolbar(removing: isActive ? .title : nil)
      .overlay(alignment: .top) {
        BotConversationTopBar(bot: bot, showsHeader: showsHeader, onOpenDetails: openDetails)
      }
      .botMascotOpen(isActive ? bot : nil)
  }

  private var isActive: Bool {
    workspaceActivity?.isActive ?? true
  }

  private var openDetails: (() -> Void)? {
    guard !bot.isArchived else { return nil }
    return { onEditBot(bot) }
  }
}
