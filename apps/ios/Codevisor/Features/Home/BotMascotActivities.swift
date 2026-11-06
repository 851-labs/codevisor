import CodevisorCore
import CodevisorUI

struct BotMascotActivities {
  let environment: AppEnvironment

  func of(_ bot: Bot) -> BotMascotActivity {
    guard let session = environment.projectList.session(bot.sessionId, serverId: bot.serverId) else {
      return .resting
    }

    let cache = ChatControllerCache.shared
    return BotMascotActivity(
      isInTurn: cache.isInProgress(session),
      isTalkingToAgent: session.talkingToAgent,
      hasActiveAgents: environment.projectList.hasAgents(startedBy: session) { agent in
        cache.isInProgress(agent) || agent.sidebarState == .waitingForUser
      }
    )
  }

  func read() {
    BotMascotActivitySource.shared.read { of($0) }
  }
}
