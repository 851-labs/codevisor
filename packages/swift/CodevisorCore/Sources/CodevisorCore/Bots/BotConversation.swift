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
  public let lastActivityAt: Date?
  public let activity: Activity
  public let isUnread: Bool

  public init(bot: Bot, session: ChatSession?, activity: Activity, isUnread: Bool) {
    self.bot = bot
    self.preview = session.flatMap { Self.previewText($0.latestBotMessage) }
    self.lastActivityAt = session.map { $0.updatedAt ?? $0.createdAt }
    self.activity = activity
    self.isUnread = isUnread
  }

  public var id: UUID { bot.id }

  public static func byRecency(_ lhs: BotConversation, _ rhs: BotConversation) -> Bool {
    let left = lhs.lastActivityAt ?? .distantPast
    let right = rhs.lastActivityAt ?? .distantPast
    guard left == right else { return left > right }

    return lhs.bot.name.localizedStandardCompare(rhs.bot.name) == .orderedAscending
  }

  static func previewText(_ message: BotMessagePreview?) -> String? {
    guard let message else { return nil }

    let text = message.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if !text.isEmpty { return text }
    return message.attachmentNames.first.map { "Attachment: \($0)" }
  }
}
