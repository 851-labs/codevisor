import CodevisorCore
import SwiftUI

extension HomeView {
  func openBot(_ bot: Bot) {
    IOSNavigationDiagnostics.record("home.openBot", "bot=\(shortID(bot.id)) pathBefore=\(navigationPathSummary(path))")
    openRoute(.bot(serverId: bot.serverId, botId: bot.id))
  }

  func setBotArchived(_ bot: Bot, _ isArchived: Bool) {
    if isArchived { closeBot(bot) }
    Task {
      do {
        try await environment.bots.setArchived(bot, isArchived)
      } catch {
        ErrorReporter.shared.report(isArchived ? "Couldn't archive bot" : "Couldn't unarchive bot", error: error)
      }
    }
  }

  func closeBot(_ bot: Bot) {
    let route = HomeRoute.bot(serverId: bot.serverId, botId: bot.id)
    guard path.contains(route) else { return }
    if layoutMode == .split {
      selectDetail(nil)
    } else {
      path.removeAll { $0 == route }
    }
  }
}
