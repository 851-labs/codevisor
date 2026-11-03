import CodevisorCore
import SwiftUI

struct BotConversationChrome: ViewModifier {
  let bot: Bot
  @FocusedValue(\.botListActions) private var actions

  func body(content: Content) -> some View {
    content
      .environment(\.transcriptTopChromeHeight, BotConversationHeader.height)
      .toolbar(removing: .title)
      .overlay(alignment: .top) {
        BotConversationTopBar(bot: bot, onOpenDetails: openDetails)
      }
  }

  private var openDetails: (() -> Void)? {
    guard !bot.isArchived, let actions else { return nil }
    return { actions.editBot(bot) }
  }
}
