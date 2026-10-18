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

  public func botDeletionMessage(for bot: Bot) -> String {
    let removal =
      "The bot's chat, its worktrees in \(bot.rootPath), and their codevisor/bot branches will be removed. Uncommitted and unpushed work in those worktrees will be lost."
    switch navigationStore.workspaceEntries.botChildren[bot.id]?.count ?? 0 {
    case 0: return removal
    case 1: return removal + " Its workspace will be archived."
    case let count: return removal + " Its \(count) workspaces will be archived."
    }
  }
}
