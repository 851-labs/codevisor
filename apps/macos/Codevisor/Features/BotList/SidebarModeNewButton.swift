import CodevisorUI
import SwiftUI

struct SidebarModeNewButton: View {
  let mode: SidebarMode
  let newChat: () -> Void
  let newBot: () -> Void

  var body: some View {
    switch mode {
    case .bots: BotComposeButton(onNewBot: newBot)
    case .code: NewChatComposeButton(onNewChat: newChat)
    }
  }
}
