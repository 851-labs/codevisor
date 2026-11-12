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

  private func conversation(message: BotMessagePreview?) throws -> BotConversation {
    let bot = try #require(Bot(serverId: "local", record: ServerBot.fixture()))
    let session = ChatSession(
      id: bot.sessionId, projectId: bot.projectId, createdAt: Self.reference, latestBotMessage: message)
    return BotConversation(bot: bot, session: session, home: nil, activity: .idle, isUnread: false)
  }
}
