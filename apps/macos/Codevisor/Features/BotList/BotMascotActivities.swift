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
      isWorking: store.isInProgress(session),
      isWaitingOnAgents: environment.projectList.runningAgents(startedBy: session, isRunning: store.isInProgress)
    )
  }
}
