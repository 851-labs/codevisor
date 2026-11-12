import CodevisorCore
import Foundation

@MainActor
struct TranscriptEventAgents {
  private static let agentEventTypes: Set<String> = [
    "session.turn_ended", "session.waiting_for_user", "session.errored", TranscriptEvent.agentMessageType,
  ]

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

  func icon(for event: TranscriptEvent) -> TranscriptEventIconKind {
    if let bot = bot(for: event) { return .bot(bot) }
    guard let session = session(for: event), !session.harnessId.isEmpty else { return .symbol("person.crop.circle") }
    return .harness(session.harnessId)
  }

  private static func agentId(of event: TranscriptEvent) -> String? {
    guard isAgentEvent(event) else { return nil }
    return event[attribute: "from"] ?? event[attribute: "agentId"]
  }
}
