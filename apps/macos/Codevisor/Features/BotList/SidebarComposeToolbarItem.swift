import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarComposeToolbarItem: ToolbarContent {
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  @Environment(\.appIsCovered) private var appIsCovered
  @Environment(AppEnvironment.self) private var environment

  @SidebarSelectionRef var selection: SidebarSelection?
  let newChat: () -> Void
  let newBot: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      switch storedMode {
      case .bots:
        if let openThread {
          BotThreadBackButton(thread: openThread)
        } else {
          BotComposeButton(onNewBot: newBot)
        }
      case .code: NewChatComposeButton(onNewChat: newChat)
      }
    }
    .hidden(appIsCovered || showsBotsEmptyState)
  }

  private var showsBotsEmptyState: Bool {
    storedMode == .bots && showsBlankPage && !BotListAvailability(environment: environment).hasBots
  }

  private var showsBlankPage: Bool {
    switch selection {
    case .none, .newChat: true
    case .session, .workspace, .archivedWorkspace, .bot: false
    }
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
