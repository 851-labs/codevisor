import CodevisorCore
import SwiftUI

struct BotConversationChrome: ViewModifier {
  let bot: Bot
  let showsHeader: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusedValue(\.botListActions) private var actions

  func body(content: Content) -> some View {
    content
      .animation(BotConversationTopBar.animation(reduceMotion: reduceMotion)) {
        $0.modifier(TranscriptTopChromeInset(height: BotConversationTopBar.height(showsHeader: showsHeader)))
      }
      .toolbar(removing: .title)
      .overlay(alignment: .top) {
        BotConversationTopBar(bot: bot, showsHeader: showsHeader, onOpenDetails: openDetails)
      }
  }

  private var openDetails: (() -> Void)? {
    guard !bot.isArchived, let actions else { return nil }
    return { actions.editBot(bot) }
  }
}
