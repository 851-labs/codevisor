public enum BotMode: String, CaseIterable, Identifiable, Sendable {
  case transcript
  case bubbles
  case conversation

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .transcript: "Transcript"
    case .bubbles: "Transcript with Bubbles"
    case .conversation: "Conversation"
    }
  }

  public var summary: String {
    switch self {
    case .transcript:
      "See everything the bot does, including its tool calls, like any other chat."
    case .bubbles:
      "See the bot's replies as message bubbles, one per paragraph, table, or code block. Tool calls are hidden."
    case .conversation:
      "Chat with the bot like a messaging app. You see only the messages it sends you, you can message it while it works, and it tells you when its agents finish."
    }
  }
}
