import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotComposeToolbarItem: ToolbarContent {
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  @Environment(\.appIsCovered) private var appIsCovered
  @Environment(AppEnvironment.self) private var environment

  @SidebarSelectionRef var selection: SidebarSelection?
  let newBot: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      if let openThread {
        BotThreadBackButton(thread: openThread)
      } else {
        BotComposeButton(onNewBot: newBot)
      }
    }
    .hidden(appIsCovered || storedMode != .bots || showsBotsEmptyState)
  }

  private var showsBotsEmptyState: Bool {
    selection.showsNewChat && !BotListAvailability(environment: environment).hasBots
  }

  private var openThread: OpenBotThread? {
    guard case let .bot(serverId, botId) = selection,
      let bot = environment.bots.bot(serverId: serverId, id: botId),
      environment.hasOpenPage(bot)
    else { return nil }

    return OpenBotThread(botName: bot.name) { [botThreads = environment.botThreads] in
      botThreads.closePage(of: bot)
    }
  }
}
