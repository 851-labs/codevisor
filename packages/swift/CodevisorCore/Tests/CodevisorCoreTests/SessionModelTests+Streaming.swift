import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("A live question turn adopts the server transcript item identity")
  func liveQuestionTurnAdoptsCanonicalItemIdentity() async {
    let sessionId = UUID()
    let assistantItemId = UUID()
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
    await model.loadHistory()
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
    #expect(model.activeFinishedResponseItemId == nil)

    client.emit(
      ServerEventEnvelope(
        id: 2,
        serverId: "local",
        kind: "session.output",
        subjectId: sessionId.uuidString,
        createdAt: "2026-08-19T00:00:01.000Z",
        payload: .object([
          "sessionUpdate": .string("question"),
          "questionId": .string("q-identity"),
          "questions": .array([
            .object([
              "id": .string("choice"),
              "question": .string("Continue?"),
              "allowsOther": .bool(false),
              "options": .array([.object(["label": .string("Yes")])]),
            ])
          ]),
        ])
      ))
    client.emit(
      ServerEventEnvelope(
        id: 3,
        serverId: "local",
        kind: "session.output",
        subjectId: sessionId.uuidString,
        createdAt: "2026-08-19T00:00:02.000Z",
        payload: .object([
          "sessionUpdate": .string("question_resolved"),
          "questionId": .string("q-identity"),
          "outcome": .string("answered"),
          "questions": .array([]),
          "answers": .object([:]),
        ])
      ))
    client.emit(
      ServerEventEnvelope(
        id: 4,
        serverId: "local",
        kind: "session.output",
        subjectId: sessionId.uuidString,
        createdAt: "2026-08-19T00:00:03.000Z",
        payload: .object([
          "sessionUpdate": .string("agent_message_chunk"),
          "messageId": .string("answer-identity"),
          "content": .object(["type": .string("text"), "text": .string("Done")]),
        ])
      ))
    client.emit(
      ServerEventEnvelope(
        id: 5,
        serverId: "local",
        kind: "session.updated",
        subjectId: sessionId.uuidString,
        createdAt: "2026-08-19T00:00:04.000Z",
        payload: .object([
          "chatItemId": .string(assistantItemId.uuidString),
          "stopReason": .string("end_turn"),
          "turnId": .string("turn-question"),
          "turnState": .string("ended"),
        ])
      ))

    await settleAssistant(model) { !$0.turn.isGenerating }
    guard case let .assistant(assistant) = model.conversation.last else {
      Issue.record("expected assistant")
      return
    }
    #expect(assistant.id == assistantItemId)
    #expect(model.activeFinishedResponseItemId == assistantItemId)
    guard case let .text(_, markdown) = assistant.turn.finalText else {
      Issue.record("expected final text")
      return
    }
    #expect(markdown == "Done")
  }

  @Test("Server-backed sessions prompt through the server and consume event stream output")
  func serverBackedSendStreams() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      now: { Date(timeIntervalSince1970: 100) }
    )

    await model.send("hello server")
    await settleUntil { !model.isSending }

    #expect(client.promptedTexts == ["hello server"])
    #expect(model.conversation.count == 2)
    guard case let .assistant(assistant) = model.conversation.last else {
      Issue.record("expected assistant")
      return
    }
    #expect(assistant.turn.finalText == .text(id: "t0", markdown: "Echo: hello server"))
    #expect(assistant.turn.stopReason == .endTurn)
    // A clean completion carries no reason — the transcript stays quiet.
    #expect(assistant.turn.stopDetail == nil)
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

    // Claiming removes the item from the visible queue immediately before
    // the server materializes that same id as a user transcript message.
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

    // Explicit deletion creates the same queue diff, but a later remote
    // row has a different id and therefore must not look like a promotion.
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

    // The harness re-triggered itself off a finished background task: an
    // agent-initiated turn starts and adopts the server item identity.
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

    // A user message interleaves before the turn's terminal event —
    // it settles the still-generating agent bubble mid-transcript.
    model.apply(.userMessage(id: UUID().uuidString, text: "and another thing", attachments: []))

    // The agent turn's terminal event routes to its (now settled) bubble
    // by identity instead of closing whatever happens to be active.
    model.apply(
      .finished(.endTurn, stopDetail: nil, initiatedBy: .agent, chatItemId: agentItemId))

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
    // The user's follow-up turn is still live: the session stays busy.
    #expect(model.isSending)

    // The follow-up's own terminal event clears the session busy state.
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
}
