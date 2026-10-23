import Foundation

public struct BotSidebarEntry: Identifiable, Equatable {
  public let bot: Bot
  public let children: [WorkspaceSidebarItem]

  public var id: UUID { bot.id }

  public var workspaceIDs: [UUID] { [bot.workspaceId] + children.map(\.id) }

  static func isChild(_ child: WorkspaceSidebarItem, of bot: Bot, botServerId: String?) -> Bool {
    guard let botMachineId = child.botMachineId else { return child.serverId == bot.serverId }
    return botMachineId == botServerId
  }
}

extension AppEnvironment {
  public var botSidebarEntries: [BotSidebarEntry] {
    let children = navigationStore.workspaceEntries.botChildren
    let statuses = machines.statusByMachineId
    return bots.bots.map { bot in
      let botServerId = statuses[bot.serverId]?.serverId
      return BotSidebarEntry(
        bot: bot,
        children: (children[bot.id] ?? []).filter {
          BotSidebarEntry.isChild($0, of: bot, botServerId: botServerId)
        })
    }
  }

  public var defaultBotServerId: String {
    let preferred = defaultComposerServerId
    if bots.supportsBots(on: preferred) { return preferred }
    return bots.botMachines.first?.id ?? preferred
  }
}
