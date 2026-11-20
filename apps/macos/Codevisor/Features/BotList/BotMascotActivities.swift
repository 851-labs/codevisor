import CodevisorCore
import CodevisorUI

struct BotMascotActivities {
  let environment: AppEnvironment
  let store: SessionStore?

  func of(_ bot: Bot) -> BotMascotActivity {
    guard let store, let session = environment.projectList.session(bot.sessionId, serverId: bot.serverId) else {
      return .resting
    }

    let agents = environment.projectList
    return BotMascotActivity(
      isInTurn: store.isInProgress(session),
      isTalkingToAgent: session.talkingToAgent,
      hasWorkingAgents: agents.hasAgents(startedBy: session) { store.isInProgress($0) },
      hasAgentsWaitingOnYou: agents.hasAgents(startedBy: session) { $0.sidebarState == .waitingForUser },
      hasMessages: session.latestBotMessage != nil
    )
  }
}
