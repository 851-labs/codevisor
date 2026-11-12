import Foundation

public struct BotConversation: Identifiable, Equatable, Sendable {
  public enum Activity: Equatable, Sendable {
    case idle
    case working
    case waitingOnUser
    case failed
  }

  public let bot: Bot
  public let preview: String?
  public let sidebarPosition: String
  public let archivedAt: Date?
  public let activity: Activity
  public let isUnread: Bool

  public init(bot: Bot, session: ChatSession?, home: Workspace?, activity: Activity, isUnread: Bool) {
    self.bot = bot
    self.preview = session.flatMap { Self.previewText($0.latestBotMessage) }
    self.sidebarPosition = BotSidebarOrder.position(of: bot, home: home)
    self.archivedAt = bot.isArchived ? bot.archivedAt ?? bot.createdAt ?? .distantPast : nil
    self.activity = activity
    self.isUnread = isUnread
  }

  public var id: UUID { bot.id }

  static func previewText(_ message: BotMessagePreview?) -> String? {
    guard let message else { return nil }

    let text = message.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if !text.isEmpty { return text }
    return message.attachmentNames.first.map { "Attachment: \($0)" }
  }
}
