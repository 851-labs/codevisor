import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarComposeToolbarItem: ToolbarContent {
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  @Environment(\.firstLaunchCoversApp) private var firstLaunchCoversApp
  @Environment(AdaptivePanelLayout.self) private var panelLayout

  let newChat: () -> Void
  let newBot: () -> Void
  let openThread: OpenBotThread?

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      if let shownThread {
        BotThreadBackButton(thread: shownThread)
      } else {
        SidebarModeNewButton(mode: storedMode, newChat: newChat, newBot: newBot)
      }
    }
    .hidden(firstLaunchCoversApp || !showsButton)
  }

  private var shownThread: OpenBotThread? {
    storedMode == .bots ? openThread : nil
  }

  private var showsButton: Bool {
    shownThread != nil || !sidebarShowsNewButton
  }

  private var sidebarShowsNewButton: Bool {
    SidebarModeSwitchPlacement.current == .sidebar
      && !RootSidebarVisibility(panelLayout: panelLayout).hidesDockedColumn
  }
}
