import Foundation

public struct BotSidebarEntry: Identifiable, Equatable {
  public let bot: Bot
  public let children: [WorkspaceSidebarItem]

  public var id: UUID { bot.id }

  public var workspaceIDs: [UUID] { [bot.workspaceId] + children.map(\.id) }
}

extension AppEnvironment {
  public var botSidebarEntries: [BotSidebarEntry] {
    let children = navigationStore.workspaceEntries.botChildren
    return bots.bots.map { bot in
      BotSidebarEntry(bot: bot, children: (children[bot.id] ?? []).filter { $0.serverId == bot.serverId })
    }
  }

  public var defaultBotServerId: String {
    let preferred = defaultComposerServerId
    if bots.supportsBots(on: preferred) { return preferred }
    return bots.botMachines.first?.id ?? preferred
  }
}
