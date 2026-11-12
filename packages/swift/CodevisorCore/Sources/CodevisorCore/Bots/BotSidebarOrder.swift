import Foundation

public struct BotSidebarPlacement: Equatable, Sendable {
  public var section: UUID?
  public var after: UUID?

  public init(section: UUID?, after: UUID?) {
    self.section = section
    self.after = after
  }
}

public enum BotSidebarOrder {
  public static func sorted(_ conversations: [BotConversation]) -> [BotConversation] {
    conversations.sorted(by: precedes)
  }

  public static func placement(
    of botID: UUID, in conversations: [BotConversation], membership: [UUID: UUID]
  ) -> BotSidebarPlacement {
    let section = membership[botID]
    let siblings = members(of: section, in: conversations, membership: membership)
    guard let index = siblings.firstIndex(where: { $0.id == botID }), index > 0 else {
      return BotSidebarPlacement(section: section, after: nil)
    }
    return BotSidebarPlacement(section: section, after: siblings[index - 1].id)
  }

  public static func siblings(
    placing bot: Bot, at placement: BotSidebarPlacement, in conversations: [BotConversation],
    membership: [UUID: UUID]
  ) -> [Bot] {
    var siblings = members(of: placement.section, in: conversations, membership: membership)
      .map(\.bot).filter { $0.id != bot.id }
    let predecessor = placement.after.flatMap { after in siblings.firstIndex { $0.id == after } }
    siblings.insert(bot, at: predecessor.map { $0 + 1 } ?? 0)
    return siblings
  }

  static func position(of bot: Bot, home: Workspace?) -> String {
    home?.effectiveSidebarPosition
      ?? WorkspacePosition.initial(createdAt: bot.createdAt ?? .distantPast, id: bot.workspaceId)
  }

  private static func members(
    of section: UUID?, in conversations: [BotConversation], membership: [UUID: UUID]
  ) -> [BotConversation] {
    sorted(conversations).filter { !$0.bot.isArchived && membership[$0.id] == section }
  }

  private static func precedes(_ lhs: BotConversation, _ rhs: BotConversation) -> Bool {
    if lhs.bot.isArchived != rhs.bot.isArchived { return rhs.bot.isArchived }
    if let left = lhs.archivedAt, let right = rhs.archivedAt, left != right { return left > right }
    if lhs.sidebarPosition != rhs.sidebarPosition { return lhs.sidebarPosition < rhs.sidebarPosition }
    if lhs.bot.serverId != rhs.bot.serverId { return lhs.bot.serverId < rhs.bot.serverId }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
