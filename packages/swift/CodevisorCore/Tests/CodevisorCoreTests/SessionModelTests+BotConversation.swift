import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

extension SessionModelTests {
  @Test("A bot chat shows its feed and delivers messages sent while the bot works instead of queueing them")
  func botConversationFeedAndSendWhileWorking() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.initialTranscriptPage = ServerTranscriptPage(items: [], hasMore: false, eventCursor: 0)
    client.botConversationPage = ServerBotConversationPage(
      messages: [botFeedMessage("b1", .bot, "Hi there", sequence: 1, sessionId: sessionId)],
      hasMore: false,
      working: false
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    model.presentBotConversation()
    await model.loadHistoryForInitialDisplay()
    await settleUntil { model.botMessages.count == 1 && !client.sessionEventSinceValues.isEmpty }

    client.emit(
      botEnvelope(
        1, sessionId, "session.updated",
        [
          "chatItemId": .string(UUID().uuidString),
          "turnId": .string("turn-bot"),
          "turnState": .string("started"),
        ]))
    await settleUntil { model.isSending }
    let followUp = UserMessage(text: "and add a test")
    await model.send(followUp)
    let followUpID = followUp.id.uuidString.lowercased()

    #expect(client.promptedMessageIds.last == followUpID)
    #expect(model.transcriptBotConversation?.messages.map(\.id) == ["b1", followUpID])
    #expect(model.transcriptBotConversation?.isWorking == true)

    let echo = botFeedMessage(followUpID, .user, "and add a test", sequence: 2, sessionId: sessionId)
    client.emit(botEnvelope(2, sessionId, "bot.message", ["message": botJSON(echo)]))
    await settleUntil { model.botMessages.count == 2 }

    #expect(model.transcriptBotConversation?.messages.map(\.id) == ["b1", followUpID])
  }

  private func botFeedMessage(
    _ id: String, _ sender: ServerBotMessageSender, _ text: String, sequence: Int, sessionId: UUID
  ) -> ServerBotMessage {
    ServerBotMessage(
      id: id, sessionId: sessionId.uuidString.lowercased(), sequence: sequence, sender: sender, text: text,
      createdAt: "2026-10-18T09:00:0\(sequence).000Z")
  }

  private func botJSON(_ message: ServerBotMessage) -> JSONValue {
    let data = try! JSONEncoder().encode(message)
    return try! JSONDecoder().decode(JSONValue.self, from: data)
  }

  private func botEnvelope(
    _ id: Int, _ sessionId: UUID, _ kind: String, _ payload: [String: JSONValue]
  ) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: id, serverId: "local", kind: kind, subjectId: sessionId.uuidString,
      createdAt: "2026-10-18T09:00:00.000Z", payload: .object(payload))
  }
}
