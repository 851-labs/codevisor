import CodevisorCore
import Foundation

struct BotMascotStageKey: Hashable, Sendable {
  let serverId: String
  let botId: UUID

  init(serverId: String, botId: UUID) {
    self.serverId = serverId
    self.botId = botId
  }

  init(_ bot: Bot) {
    self.init(serverId: bot.serverId, botId: bot.id)
  }
}
