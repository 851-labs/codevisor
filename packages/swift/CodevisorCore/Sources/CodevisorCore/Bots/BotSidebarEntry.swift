import Foundation

public struct BotSidebarEntry: Identifiable, Equatable {
  public let bot: Bot

  public var id: UUID { bot.id }
}

extension AppEnvironment {
  public var botSidebarEntries: [BotSidebarEntry] {
    bots.bots.map(BotSidebarEntry.init(bot:))
  }

  public var defaultBotServerId: String {
    let preferred = defaultComposerServerId
    if bots.supportsBots(on: preferred) { return preferred }
    return bots.botMachines.first?.id ?? preferred
  }
}
