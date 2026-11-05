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
      isWorking: cache.isInProgress(session),
      isWaitingOnAgents: environment.projectList.runningAgents(startedBy: session, isRunning: cache.isInProgress)
    )
  }

  func read() {
    BotMascotActivitySource.shared.read { of($0) }
  }
}
