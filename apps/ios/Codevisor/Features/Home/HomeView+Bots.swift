import CodevisorCore
import SwiftUI

extension HomeView {
  func openBot(_ bot: Bot) {
    IOSNavigationDiagnostics.record("home.openBot", "bot=\(shortID(bot.id)) pathBefore=\(navigationPathSummary(path))")
    if bot.mode != .transcript || bot.isArchived {
      openRoute(.bot(serverId: bot.serverId, botId: bot.id))
    } else if let session = projectList.session(bot.sessionId, serverId: bot.serverId) {
      ChatControllerCache.shared.existingController(sessionId: bot.sessionId, serverId: bot.serverId)?
        .presentBot(as: .transcript)
      openChat(session)
    }
  }

  func openNewTab(forBot bot: Bot) {
    addSidebarTab(
      in: HomeSidebarWorkspaceRef(id: bot.workspaceId, serverId: bot.serverId, anchorSessionId: bot.sessionId))
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
