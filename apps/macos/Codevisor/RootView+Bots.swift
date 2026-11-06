import CodevisorCore
import CodevisorUI
import SwiftUI

extension RootView {
  var showsBotConversation: Bool {
    guard botsEnabled, case .bot = selection else { return false }
    return true
  }

  var rootActions: RootSidebarActions? {
    guard store != nil else { return nil }
    return RootSidebarActions(
      newChat: openNewChat, newBot: botsEnabled ? openNewBot : nil, editBot: editBot)
  }

  func openNewChat() {
    selection = .newChat(nil)
    sidebarMode = .code
  }

  func editBot(_ bot: Bot) {
    botEditor = .edit(bot)
  }

  func openNewBot() {
    sidebarMode = .chat
    botEditor = .create
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
      .modifier(BotConversationChrome(bot: bot, showsHeader: showsBotConversationHeader, onEditBot: editBot))
    } else {
      ContentUnavailableView(
        "Bot Unavailable",
        systemImage: "sparkles",
        description: Text("This bot was deleted or its machine is not connected.")
      )
    }
  }
}
