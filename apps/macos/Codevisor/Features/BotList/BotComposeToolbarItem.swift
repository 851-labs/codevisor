import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotComposeToolbarItem: ToolbarContent {
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) { BotComposeToolbarButton() }
      .hidden(SidebarMode.active(storedMode, botsEnabled: botsEnabled) != .chat)
  }
}
