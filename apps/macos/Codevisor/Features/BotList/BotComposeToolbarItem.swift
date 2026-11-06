import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotComposeToolbarItem: ToolbarContent {
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode

  let newBot: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) { BotComposeButton(onNewBot: newBot) }
      .hidden(SidebarMode.active(storedMode, botsEnabled: botsEnabled) != .chat)
  }
}
