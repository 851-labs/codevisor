import CodevisorCore
import SwiftUI

extension RootView {
  @ViewBuilder
  func botDetail(_ store: SessionStore, serverId: String, botId: UUID) -> some View {
    if botsEnabled, let bot = environment.bots.bot(serverId: serverId, id: botId) {
      SessionRouteView(
        store: store,
        serverId: serverId,
        sessionId: bot.sessionId,
        onFocusedChatChanged: { chatId in
          guard chatId != bot.sessionId else { return }
          selection = .session(serverId: serverId, id: chatId)
        },
        onDisposition: { _ in }
      )
    } else {
      ContentUnavailableView(
        "Bot Unavailable",
        systemImage: "sparkles",
        description: Text("This bot was deleted or its machine is not connected.")
      )
    }
  }
}
