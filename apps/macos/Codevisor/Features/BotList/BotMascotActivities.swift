import CodevisorCore
import CodevisorUI

struct BotMascotActivities {
  let environment: AppEnvironment
  let store: SessionStore?

  func of(_ bot: Bot) -> BotMascotActivity {
    guard let store, let session = environment.projectList.session(bot.sessionId, serverId: bot.serverId) else {
      return .resting
    }

    return BotMascotActivity(
      isInTurn: store.isInProgress(session),
      isTalkingToAgent: session.talkingToAgent,
      hasActiveAgents: environment.projectList.hasAgents(startedBy: session) { agent in
        store.isInProgress(agent) || agent.sidebarState == .waitingForUser
      }
    )
  }
}
