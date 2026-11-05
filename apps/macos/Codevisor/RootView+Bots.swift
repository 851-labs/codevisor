import CodevisorCore
import CodevisorUI
import SwiftUI

extension RootView {
  var showsBotConversation: Bool {
    guard botsEnabled, case .bot = selection else { return false }
    return true
  }

  func readBotMascotActivity() {
    let activities = BotMascotActivities(environment: environment, store: store)
    BotMascotActivitySource.shared.read { activities.of($0) }
  }

  var showsBotConversationHeader: Bool {
    !panelLayout.docksSidebar || sidebarCollapsed
  }

  @ViewBuilder
  func botDetail(_ store: SessionStore, serverId: String, botId: UUID) -> some View {
    if botsEnabled, let bot = environment.bots.bot(serverId: serverId, id: botId) {
      SessionRouteView(
        store: store,
        serverId: serverId,
        sessionId: bot.sessionId,
        onFocusedChatChanged: { _ in },
        onDisposition: { _ in }
      )
      .modifier(BotConversationChrome(bot: bot, showsHeader: showsBotConversationHeader))
      .botMascotOpen(bot)
    } else {
      ContentUnavailableView(
        "Bot Unavailable",
        systemImage: "sparkles",
        description: Text("This bot was deleted or its machine is not connected.")
      )
    }
  }
}
