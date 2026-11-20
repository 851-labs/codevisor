import CodevisorCore
import CodevisorUI

struct BotMascotActivities {
  let environment: AppEnvironment

  func of(_ bot: Bot) -> BotMascotActivity {
    guard let session = environment.projectList.session(bot.sessionId, serverId: bot.serverId) else {
      return .resting
    }

    let cache = ChatControllerCache.shared
    let agents = environment.projectList
    return BotMascotActivity(
      isInTurn: cache.isInProgress(session),
      isTalkingToAgent: session.talkingToAgent,
      hasWorkingAgents: agents.hasAgents(startedBy: session) { cache.isInProgress($0) },
      hasAgentsWaitingOnYou: agents.hasAgents(startedBy: session) { $0.sidebarState == .waitingForUser },
      hasMessages: session.latestBotMessage != nil
    )
  }

  func read() {
    BotMascotActivitySource.shared.read { of($0) }
  }
}
