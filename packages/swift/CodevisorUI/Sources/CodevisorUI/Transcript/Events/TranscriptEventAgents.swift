import CodevisorCore
import Foundation

@MainActor
struct TranscriptEventAgents {
  private static let agentEventTypes: Set<String> = [
    "session.turn_ended", "session.waiting_for_user", "session.errored", TranscriptEvent.agentMessageType,
  ]

  static let threadSymbol = "bubble.left.and.bubble.right"

  let sessions: [ChatSession]
  let bots: BotListModel?

  static func isAgentEvent(_ event: TranscriptEvent) -> Bool {
    agentEventTypes.contains(event.type)
  }

  func session(for event: TranscriptEvent) -> ChatSession? {
    guard let id = Self.agentId(of: event).flatMap(UUID.init(uuidString:)) else { return nil }
    return sessions.first { $0.id == id }
  }

  func bot(for event: TranscriptEvent) -> Bot? {
    guard let session = session(for: event) else { return nil }
    return bots?.bot(forSession: session.id, serverId: session.serverId)
  }

  func name(for event: TranscriptEvent) -> String {
    if let bot = bot(for: event) { return bot.name }
    guard let title = session(for: event)?.title, !title.isEmpty else { return "Agent" }
    return title
  }

  func icon(for event: TranscriptEvent) -> TranscriptEventIconKind {
    if let bot = bot(for: event) { return .bot(bot) }
    guard let session = session(for: event), !session.harnessId.isEmpty else { return .symbol("person.crop.circle") }
    return .harness(session.harnessId)
  }

  func threadPartyIcon(for event: TranscriptEvent) -> TranscriptEventIconKind {
    if let id = event[attribute: "botId"]?.lowercased(),
      let bot = bots?.bots.first(where: { $0.record.id.lowercased() == id })
    {
      return .bot(bot)
    }
    let agent = event[attribute: "agentId"].flatMap(UUID.init(uuidString:))
    guard let session = sessions.first(where: { $0.id == agent }), !session.harnessId.isEmpty else {
      return .symbol(Self.threadSymbol)
    }
    return .harness(session.harnessId)
  }

  private static func agentId(of event: TranscriptEvent) -> String? {
    guard isAgentEvent(event) else { return nil }
    return event[attribute: "from"] ?? event[attribute: "agentId"]
  }
}
