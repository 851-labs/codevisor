import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("A live question turn adopts the server transcript item identities on both sides of the question")
  func liveQuestionTurnAdoptsCanonicalItemIdentity() async {
    let sessionId = UUID()
    let assistantItemId = UUID()
    let continuationItemId = UUID()
    let questions: JSONValue = .array([
      .object([
        "id": .string("choice"),
        "question": .string("Continue?"),
        "allowsOther": .bool(false),
        "options": .array([.object(["label": .string("Yes")])]),
      ])
    ])
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [],
      hasMore: false,
      eventCursor: 0
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.loadHistoryForInitialDisplay()
    await settleUntil { !client.sessionEventSinceValues.isEmpty }

    client.emit(
      ServerEventEnvelope(
        id: 1,
        serverId: "local",
        kind: "session.updated",
        subjectId: sessionId.uuidString,
        createdAt: "2026-08-19T00:00:00.000Z",
        payload: .object([
          "chatItemId": .string(assistantItemId.uuidString),
          "turnId": .string("turn-question"),
          "turnState": .string("started"),
        ])
      ))
    await settleUntil { model.activeItem?.id == assistantItemId }

    client.emit(
      outputEnvelope(
        2, sessionId,
        [
          "sessionUpdate": .string("question"),
          "questionId": .string("q-identity"),
          "questions": questions,
        ]))
    client.emit(
      outputEnvelope(
        3, sessionId,
        [
          "sessionUpdate": .string("question_resolved"),
          "questionId": .string("q-identity"),
          "outcome": .string("answered"),
          "questions": questions,
          "answers": .object(["choice": .object(["answers": .array([.string("Yes")])])]),
          "assistantItemId": .string(continuationItemId.uuidString),
        ]))
    client.emit(
      outputEnvelope(
        4, sessionId,
        [
          "sessionUpdate": .string("agent_message_chunk"),
          "messageId": .string("answer-identity"),
          "content": .object(["type": .string("text"), "text": .string("Done")]),
        ]))
    client.emit(
      ServerEventEnvelope(
        id: 5,
        serverId: "local",
        kind: "session.updated",
        subjectId: sessionId.uuidString,
        createdAt: "2026-08-19T00:00:04.000Z",
        payload: .object([
          "chatItemId": .string(continuationItemId.uuidString),
          "stopReason": .string("end_turn"),
          "turnId": .string("turn-question"),
          "turnState": .string("ended"),
        ])
      ))

    await settleUntil { model.conversation.last?.id == continuationItemId && !model.isSending }
    guard case let .assistant(assistant) = model.conversation.last else {
      Issue.record("expected assistant")
      return
    }
    let asked = model.conversation.first { $0.id == assistantItemId }
    guard case let .assistant(question)? = asked else {
      Issue.record("expected the question's section")
      return
    }
    #expect(question.turn.interactions.items.map(\.isPending) == [false])
    guard case let .text(_, markdown) = assistant.turn.finalText else {
      Issue.record("expected final text")
      return
    }
    #expect(markdown == "Done")
  }

  @Test("Prompt acceptance callback fires only after each queue item is accepted")
  func promptAcceptanceCallback() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    var attachmentCounts: [Int] = []
    var queuedStates: [Bool] = []
    model.onPromptAccepted = { attachmentCount, isQueued in
      attachmentCounts.append(attachmentCount)
      queuedStates.append(isQueued)
    }

    await model.send("first")
    await model.send("queued")

    #expect(client.promptedTexts == ["first", "queued"])
    #expect(attachmentCounts == [0, 0])
    #expect(queuedStates == [false, true])
  }

  @Test("Claimed queue items announce their transcript promotion")
  func queuedPromptPromotionCallback() async {
    let sessionId = UUID()
    let queueItemId = UUID()
    let deletedQueueItemId = UUID()
    let unrelatedMessageId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    var promotedMessageIDs: [UUID?] = []
    model.onQueuedPromptPromoted = { promotedMessageIDs.append($0) }

    await model.send("first")
    client.emit(
      ServerEventEnvelope(
        id: 1,
        serverId: "local",
        kind: "session.queue.updated",
        subjectId: sessionId.uuidString,
        createdAt: "2026-07-16T00:00:00.000Z",
        payload: .object([
          "queue": .array([
            .object([
              "id": .string(queueItemId.uuidString),
              "sessionId": .string(sessionId.uuidString),
              "text": .string("queued follow-up"),
              "createdAt": .string("2026-07-16T00:00:00.000Z"),
              "updatedAt": .string("2026-07-16T00:00:00.000Z"),
            ])
          ])
        ])
      ))
    await settleUntil { model.queuedPrompts.count == 1 }

    client.emit(
      ServerEventEnvelope(
        id: 2,
        serverId: "local",
        kind: "session.queue.updated",
        subjectId: sessionId.uuidString,
        createdAt: "2026-07-16T00:00:01.000Z",
        payload: .object(["queue": .array([])])
      ))
    client.emit(
      ServerEventEnvelope(
        id: 3,
        serverId: "local",
        kind: "session.output",
        subjectId: sessionId.uuidString,
        createdAt: "2026-07-16T00:00:01.001Z",
        payload: .object([
          "role": .string("user"),
          "messageId": .string(queueItemId.uuidString),
          "text": .string("queued follow-up"),
        ])
      ))
    await settleUntil { userMessages(model).count == 2 }

    #expect(promotedMessageIDs == [queueItemId])
    #expect(userMessages(model).last?.id == queueItemId)

    client.emit(
      ServerEventEnvelope(
        id: 4,
        serverId: "local",
        kind: "session.queue.updated",
        subjectId: sessionId.uuidString,
        createdAt: "2026-07-16T00:00:02.000Z",
        payload: .object([
          "queue": .array([
            .object([
              "id": .string(deletedQueueItemId.uuidString),
              "sessionId": .string(sessionId.uuidString),
              "text": .string("delete me"),
              "createdAt": .string("2026-07-16T00:00:02.000Z"),
              "updatedAt": .string("2026-07-16T00:00:02.000Z"),
            ])
          ])
        ])
      ))
    await settleUntil { model.queuedPrompts.count == 1 }
    client.emit(
      ServerEventEnvelope(
        id: 5,
        serverId: "local",
        kind: "session.queue.updated",
        subjectId: sessionId.uuidString,
        createdAt: "2026-07-16T00:00:03.000Z",
        payload: .object(["queue": .array([])])
      ))
    client.emit(
      ServerEventEnvelope(
        id: 6,
        serverId: "local",
        kind: "session.output",
        subjectId: sessionId.uuidString,
        createdAt: "2026-07-16T00:00:03.001Z",
        payload: .object([
          "role": .string("user"),
          "messageId": .string(unrelatedMessageId.uuidString),
          "text": .string("remote message"),
        ])
      ))
    await settleUntil { userMessages(model).count == 3 }
    #expect(promotedMessageIDs == [queueItemId])
  }

  @Test("A routed terminal event closes a settled bubble stranded mid-transcript")
  func routedFinishClosesStrandedBubble() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    let agentItemId = UUID()
    model.apply(.assistantItemStarted(agentItemId))
    model.apply(
      .update(
        .agentMessageChunk(
          .text("Task finished, wrapping up."),
          messageId: "m-agent",
          parentToolCallId: nil,
          phase: nil
        )))
    #expect(model.isSending)

    model.apply(.userMessage(id: UUID().uuidString, text: "and another thing", attachments: []))

    model.apply(
      .finished(.endTurn, stopDetail: nil, chatItemId: agentItemId))

    let settledAgent = model.conversation.first { item in
      if case let .assistant(message) = item { return message.id == agentItemId }
      return false
    }
    guard case let .assistant(agentMessage)? = settledAgent else {
      Issue.record("expected the agent bubble to remain in the conversation")
      return
    }
    #expect(agentMessage.turn.isGenerating == false)
    #expect(agentMessage.turn.stopReason == .endTurn)
    #expect(model.isSending)

    model.apply(
      .update(
        .agentMessageChunk(
          .text("Answer."),
          messageId: "m-user",
          parentToolCallId: nil,
          phase: nil
        )))
    model.apply(.finished(.endTurn, stopDetail: nil))
    #expect(model.isSending == false)
  }

  @Test("Identical queued prompts remain distinct transcript rows")
  func identicalQueuedPromptsRemainDistinct() async throws {
    let sessionId = UUID()
    let queueItemId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    await model.send("again")
    let directMessageId = try #require(userMessages(model).first?.id)
    model.apply(
      .update(
        .agentMessageChunk(
          .text("Completed the first turn."),
          messageId: "assistant-1",
          parentToolCallId: nil,
          phase: nil
        )))
    model.apply(.finished(.endTurn, stopDetail: nil))

    let queued = ServerPromptQueueItem(
      id: queueItemId.uuidString,
      sessionId: sessionId.uuidString,
      text: "again",
      createdAt: "2026-08-21T00:00:00.000Z",
      updatedAt: "2026-08-21T00:00:00.000Z"
    )
    model.apply(.queueUpdated([queued]))
    model.apply(.queueUpdated([]))
    model.apply(.userMessage(id: queueItemId.uuidString, text: "again", attachments: []))

    #expect(userMessages(model).map(\.text) == ["again", "again"])
    #expect(userMessages(model).map(\.id) == [directMessageId, queueItemId])
  }

  private func outputEnvelope(_ id: Int, _ sessionId: UUID, _ payload: [String: JSONValue]) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: id,
      serverId: "local",
      kind: "session.output",
      subjectId: sessionId.uuidString,
      createdAt: "2026-08-19T00:00:0\(id).000Z",
      payload: .object(payload)
    )
  }
}
