import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarComposeToolbarItem: ToolbarContent {
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode

  let isShowingNewChat: Bool
  let newChat: () -> Void
  let newBot: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      switch SidebarMode.active(storedMode, botsEnabled: botsEnabled) {
      case .chat: BotComposeButton(onNewBot: newBot)
      case .code: NewChatComposeButton(isSelected: isShowingNewChat, onNewChat: newChat)
      }
    }
  }
}
