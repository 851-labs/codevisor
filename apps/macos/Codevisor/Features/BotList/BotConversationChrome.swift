import CodevisorCore
import SwiftUI

struct BotConversationChrome: ViewModifier {
  let bot: Bot
  @FocusedValue(\.botListActions) private var actions

  func body(content: Content) -> some View {
    content
      .environment(\.transcriptTopChromeHeight, BotConversationHeader.height)
      .toolbar(removing: .title)
      .overlay(alignment: .top) { header }
  }

  private var header: some View {
    BotConversationHeader(
      bot: bot, onOpenDetails: bot.isArchived ? nil : actions.map { actions in { actions.editBot(bot) } }
    )
    .ignoresSafeArea(edges: .top)
  }
}
