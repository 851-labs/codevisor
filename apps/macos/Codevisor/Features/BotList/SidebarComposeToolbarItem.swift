import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarComposeToolbarItem: ToolbarContent {
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  @Environment(\.firstLaunchCoversApp) private var firstLaunchCoversApp

  let newChat: () -> Void
  let newBot: () -> Void
  let openThread: OpenBotThread?

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
    .hidden(firstLaunchCoversApp)
  }
}
