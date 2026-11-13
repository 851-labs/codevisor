import Foundation

public struct BotSidebarEntry: Identifiable, Equatable {
  public let bot: Bot

  public var id: UUID { bot.id }
}

extension AppEnvironment {
  public var botSidebarEntries: [BotSidebarEntry] {
    bots.bots.map(BotSidebarEntry.init(bot:))
  }

  public func home(of bot: Bot) -> Workspace? {
    navigationStore.workspaceEntries.entry(bot.workspaceId).workspace
  }

  public func moveBot(_ bot: Bot, to placement: BotSidebarPlacement, among conversations: [BotConversation]) {
    let membership = botSections.membership
    guard placement != BotSidebarOrder.placement(of: bot.id, in: conversations, membership: membership) else {
      return
    }

    botSections.move(bot.id, to: placement.section)
    let siblings = BotSidebarOrder.siblings(placing: bot, at: placement, in: conversations, membership: membership)
    guard siblings.count > 1 else { return }

    workspaceSync.reorderWorkspace(
      id: bot.workspaceId, visibleIDs: siblings.map(\.workspaceId), client: machines.client(for: bot.serverId))
  }
}
