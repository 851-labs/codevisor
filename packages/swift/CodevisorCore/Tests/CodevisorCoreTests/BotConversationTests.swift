import Foundation
import Testing

@testable import CodevisorCore

@Suite("Bot conversations")
struct BotConversationTests {
  private static let reference = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("The preview is the bot's latest message on one line, falling back to its first attachment")
  func previewFlattensTheLatestMessage() throws {
    let spoken = try conversation(message: BotMessagePreview(text: "Deployed\n\n  the  fix"))
    let attached = try conversation(message: BotMessagePreview(text: " \n", attachmentNames: ["log.txt", "b.png"]))
    let silent = try conversation(message: nil)

    #expect(spoken.preview == "Deployed the fix")
    #expect(attached.preview == "Attachment: log.txt")
    #expect(silent.preview == nil)
  }

  @Test("Conversations sort by latest activity, then by name, with never-active bots last")
  func sortsByRecency() throws {
    let older = try conversation(name: "Zed", updatedAt: Self.reference)
    let newer = try conversation(name: "Mia", updatedAt: Self.reference.addingTimeInterval(60))
    let tiedFirst = try conversation(name: "Ada", updatedAt: Self.reference)
    let unsynced = try conversation(name: "Bea", session: false)

    let sorted = [unsynced, older, tiedFirst, newer].sorted(by: BotConversation.byRecency)

    #expect(sorted.map(\.bot.name) == ["Mia", "Ada", "Zed", "Bea"])
  }

  @Test("Timestamps read like Messages: time today, Yesterday, weekday this week, then a date")
  func timestampsFollowMessages() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let locale = Locale(identifier: "en_US_POSIX")
    let now = Self.reference
    func text(daysAgo: Double, hour: Double = 0) -> String {
      let start = calendar.startOfDay(for: now)
      let date = start.addingTimeInterval(-daysAgo * 86_400 + hour * 3_600)
      return BotConversationTimestamp.text(for: date, now: now, calendar: calendar, locale: locale)
    }

    #expect(text(daysAgo: 0, hour: 1.5) == "1:30\u{202F}AM")
    #expect(text(daysAgo: 1, hour: 23) == "Yesterday")
    #expect(text(daysAgo: 6) == "Saturday")
    #expect(text(daysAgo: 7, hour: 23) == "1/8/27")
  }

  private func conversation(
    name: String = "Helper",
    message: BotMessagePreview? = nil,
    updatedAt: Date? = nil,
    session hasSession: Bool = true
  ) throws -> BotConversation {
    let record = ServerBot.fixture(name: name)
    let bot = try #require(Bot(serverId: "local", record: record))
    let session = ChatSession(
      id: bot.sessionId, projectId: bot.projectId, createdAt: Self.reference.addingTimeInterval(-3_600),
      updatedAt: updatedAt, latestBotMessage: message)
    return BotConversation(bot: bot, session: hasSession ? session : nil, activity: .idle, isUnread: false)
  }
}
