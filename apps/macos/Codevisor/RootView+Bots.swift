import CodevisorCore
import CodevisorUI
import SwiftUI

extension RootView {
  var showsBotConversation: Bool {
    guard case .bot = selection else { return false }
    return true
  }

  var rootActions: RootSidebarActions? {
    guard store != nil else { return nil }
    return RootSidebarActions(
      newChat: openNewChat, newBot: openNewBot, editBot: editBot)
  }

  var openBotThread: OpenBotThread? {
    guard case let .bot(serverId, botId) = selection,
      let bot = environment.bots.bot(serverId: serverId, id: botId),
      environment.botThreads.openThread(of: bot) != nil || environment.openAgentChat(of: bot) != nil
    else { return nil }
    return OpenBotThread(botName: bot.name) { [botThreads = environment.botThreads] in
      botThreads.closePage(of: bot)
    }
  }

  func openNewChat() {
    selection = .newChat(nil)
    sidebarMode = .code
  }

  func editBot(_ bot: Bot) {
    botEditor = .edit(bot)
  }

  func openNewBot() {
    sidebarMode = .bots
    botEditor = .create
  }

  func readBotMascotActivity() {
    let activities = BotMascotActivities(environment: environment, store: store)
    BotMascotActivitySource.shared.read { activities.of($0) }
  }

  @ViewBuilder
  func botDetail(_ store: SessionStore, serverId: String, botId: UUID) -> some View {
    if let bot = environment.bots.bot(serverId: serverId, id: botId) {
      SessionRouteView(
        store: store,
        serverId: serverId,
        sessionId: bot.sessionId,
        onFocusedChatChanged: { _ in },
        onDisposition: { _ in }
      )
      .modifier(BotConversationChrome(bot: bot, onEditBot: editBot))
    } else {
      ContentUnavailableView(
        "Bot Unavailable",
        systemImage: "sparkles",
        description: Text("This bot was deleted or its machine is not connected.")
      )
    }
  }
}
