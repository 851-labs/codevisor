import Foundation

public struct PresentedThread: Equatable, Sendable {
  public var conversation: TranscriptBotConversation
  public var hasOlder: Bool

  public init(conversation: TranscriptBotConversation, hasOlder: Bool) {
    self.conversation = conversation
    self.hasOlder = hasOlder
  }
}

extension TranscriptBotConversation {
  public static func thread(_ messages: [ServerThreadMessage], viewedBy bot: Bot) -> TranscriptBotConversation {
    let viewer = bot.record.id.lowercased()
    return TranscriptBotConversation(
      messages: messages.map { message in
        TranscriptBotMessage(
          id: message.id, sender: .bot, text: message.text,
          sentAt: ServerTimestamp.date(from: message.createdAt),
          side: message.from.botId?.lowercased() == viewer ? .trailing : .leading,
          author: TranscriptBotAuthor(id: message.from.botId ?? message.from.agentId, name: message.from.name))
      },
      isWorking: false)
  }
}
