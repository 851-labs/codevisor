import CodevisorClient

@MainActor
enum BotAnalytics {
  static func created(_ request: ServerCreateBotRequest, on serverId: String) {
    Analytics.capture(
      .botCreated,
      properties: [
        "harness_id": .string(request.harnessId),
        "project_count": .integer(request.projectIds.count),
        "client": .string(machineKind(serverId)),
      ])
  }

  static func forked(_ bot: Bot, _ request: ServerForkBotRequest, to serverId: String) {
    Analytics.capture(
      .botForked,
      properties: [
        "harness_id": .string(request.harnessId),
        "changed_harness": .boolean(request.harnessId != bot.harnessId),
        "other_machine": .boolean(serverId != bot.serverId),
        "moved_agents": .boolean(request.moveAgents),
      ])
  }

  static func archived(_ bot: Bot, isArchived: Bool) {
    Analytics.capture(
      .botArchived,
      properties: ["harness_id": .string(bot.harnessId), "archived": .boolean(isArchived)]
    )
  }

  static func deleted(_ bot: Bot) {
    Analytics.capture(.botDeleted, properties: ["harness_id": .string(bot.harnessId)])
  }

  private static func machineKind(_ serverId: String) -> String {
    serverId == CodevisorMachine.local.id ? "local" : "remote"
  }
}
