import ACPKit
import Foundation
import Testing
import TranscriptKit

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

  @Test("A bot message that keeps failing shows Not Delivered instead of looking sent, and Try Again delivers it")
  func botMessageThatKeepsFailingIsMarkedNotDelivered() async {
    let (client, model) = await loadedBotModel()
    client.sendAttempts.failuresLeft = 3
    let message = UserMessage(text: "are you there?")
    let id = message.id.uuidString.lowercased()

    await model.send(message)

    #expect(client.sendAttempts.actionIds == [id, id, id])
    #expect(deliveries(model) == ["b1": nil, id: .failed])
    #expect(model.transcriptBotConversation?.isWorking == false)

    await model.retryUnsentMessage(id: message.id)

    #expect(client.sendAttempts.actionIds == [id, id, id, id])
    #expect(deliveries(model) == ["b1": nil, id: nil])
    let echo = botFeedMessage(id, .user, "are you there?", sequence: 2, sessionId: client.sessionId)
    client.emit(botEnvelope(1, client.sessionId, "bot.message", ["message": botJSON(echo)]))
    await settleUntil { model.botMessages.count == 2 }
    #expect(model.outgoingMessages.isEmpty)
    model.shutdown()
  }

  @Test("A dropped send is retried with the same action id, so the server takes it once")
  func droppedBotSendIsRetriedIdempotently() async {
    let (client, model) = await loadedBotModel()
    client.sendAttempts.failuresLeft = 1
    let message = UserMessage(text: "ship it")
    let id = message.id.uuidString.lowercased()

    await model.send(message)

    #expect(client.sendAttempts.actionIds == [id, id])
    #expect(deliveries(model) == ["b1": nil, id: nil])
    #expect(model.errorMessage == nil)
    model.shutdown()
  }

  @Test("A message the server refuses isn't retried, and Delete removes it")
  func refusedBotMessageIsNotRetried() async {
    let (client, model) = await loadedBotModel()
    client.promptFailure = .httpStatus(409, "Restore the workspace before sending a prompt")
    let message = UserMessage(text: "hello?")
    let id = message.id.uuidString.lowercased()

    await model.send(message)

    #expect(client.sendAttempts.actionIds == [id])
    #expect(deliveries(model) == ["b1": nil, id: .failed])

    model.deleteUnsentMessage(id: message.id)

    #expect(deliveries(model) == ["b1": nil])
    model.shutdown()
  }

  @Test("Failed bot messages are resent once the connection catches up")
  func failedBotMessagesResendAfterReconnect() async {
    let (client, model) = await loadedBotModel()
    client.sendAttempts.failuresLeft = 3
    let message = UserMessage(text: "still there?")
    let id = message.id.uuidString.lowercased()
    await model.send(message)
    #expect(deliveries(model)[id] == .failed)

    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    client.holdPrompts(until: gate)

    model.apply(.synchronization(.caughtUp))

    await client.promptRequests.wait()
    #expect(deliveries(model)[id] == .some(.sending))
    release.finish()
    await settleUntil { deliveries(model)[id] == .some(nil) }
    #expect(client.sendAttempts.actionIds == [id, id, id, id])
    #expect(deliveries(model) == ["b1": nil, id: nil])
    model.shutdown()
  }

  @Test("A send the server hasn't confirmed yet says Sending until it does")
  func slowBotSendSaysSending() async {
    let (client, model) = await loadedBotModel()
    model.sendingNoticeDelay = .zero
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    client.holdPrompts(until: gate)
    let message = UserMessage(text: "big question")
    let id = message.id.uuidString.lowercased()

    let send = Task { await model.send(message) }
    await client.promptRequests.wait()
    await settleUntil { deliveries(model)[id] == .some(.sending) }

    release.finish()
    await send.value

    #expect(deliveries(model) == ["b1": nil, id: nil])
    model.shutdown()
  }

  @Test("A bot message the server took stays sent when only its acknowledgement was lost")
  func botMessageWithLostAcknowledgementStaysSent() async {
    let (client, model) = await loadedBotModel()
    let message = UserMessage(text: "ship it")
    let id = message.id.uuidString.lowercased()
    client.botConversationPage = ServerBotConversationPage(
      messages: [botFeedMessage(id, .user, "ship it", sequence: 2, sessionId: client.sessionId)],
      hasMore: false,
      working: true
    )
    client.promptFailure = .httpStatus(504, "Timed out")

    await model.send(message)

    #expect(client.sendAttempts.actionIds == [id, id, id])
    #expect(deliveries(model) == ["b1": nil, id: nil])
    #expect(model.errorMessage == nil)
    model.shutdown()
  }

  private func loadedBotModel() async -> (FakeSessionServerClient, SessionModel) {
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
    model.sendRetryDelays = [.zero, .zero]
    model.sendingNoticeDelay = .seconds(3600)
    model.presentBotConversation()
    await model.loadHistoryForInitialDisplay()
    await settleUntil { model.botMessages.count == 1 && !client.sessionEventSinceValues.isEmpty }
    return (client, model)
  }

  private func deliveries(_ model: SessionModel) -> [String: TranscriptDelivery?] {
    Dictionary(
      uniqueKeysWithValues: (model.transcriptBotConversation?.messages ?? []).map { ($0.id, $0.delivery) })
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
