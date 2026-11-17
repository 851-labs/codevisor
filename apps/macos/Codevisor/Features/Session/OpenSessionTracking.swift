import CodevisorCore
import SwiftUI

struct OpenSessionTracking: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Binding var selection: SidebarSelection?
  let store: SessionStore?

  func body(content: Content) -> some View {
    content.onChange(of: selection) { _, selection in markOpened(selection) }
  }

  private func markOpened(_ selection: SidebarSelection?) {
    guard let store else { return }

    if case let .session(serverId, sessionId) = selection {
      store.markOpened(sessionId, serverId: serverId)
    } else if case let .bot(serverId, botId) = selection,
      let bot = environment.bots.bot(serverId: serverId, id: botId)
    {
      store.markOpened(bot.sessionId, serverId: serverId)
    } else {
      store.clearOpenSession()
    }
  }
}
