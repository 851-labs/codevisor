import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Quiet turns surface a non-destructive stalled state")
  func quietTurnSurfacesStalledState() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionQuietTurnScheduler()
    client.echoOnPrompt = false
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: true,
      stopReason: nil,
      text: "partial answer"
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      stalledTurnQuietInterval: .seconds(300),
      quietTurnScheduler: scheduler.scheduler
    )

    await model.send("wait quietly")
    #expect(scheduler.callCount == 1)
    await scheduler.advance()
    await settleUntil {
      model.isTakingLongerThanExpected && !client.transcriptPageRequests.isEmpty
    }
    #expect(client.transcriptPageRequests.count >= 1)

    #expect(model.isSending)
    guard case let .assistant(message) = model.conversation.last else {
      Issue.record("expected assistant")
      return
    }
    #expect(message.turn.isThinking == false)
    client.emit(stopEnvelope(id: 10, sessionId: sessionId, stopReason: "end_turn"))
    await settleUntil { !model.isSending }
    #expect(model.isTakingLongerThanExpected == false)
  }

  @Test("A reload that shows server progress clears the stalled state")
  func quietTurnWithServerProgressIsNotStalled() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionQuietTurnScheduler()
    client.echoOnPrompt = false
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: false,
      stopReason: "end_turn",
      eventCursor: 2,
      text: "earlier answer"
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      stalledTurnQuietInterval: .seconds(300),
      quietTurnScheduler: scheduler.scheduler
    )
    await model.loadHistoryForInitialDisplay()
    #expect(model.serverEventCursor == 2)

    await model.send("keep working while I am away")
    #expect(scheduler.callCount == 1)

    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: true,
      stopReason: nil,
      eventCursor: 7,
      text: "partial answer"
    )
    let requestsBeforeStall = client.transcriptPageRequests.count
    await scheduler.advance()

    #expect(client.transcriptPageRequests.count == requestsBeforeStall + 1)
    #expect(scheduler.callCount == 2)
    #expect(model.serverEventCursor == 7)
    #expect(model.isSending)
    #expect(model.isTakingLongerThanExpected == false)
    model.endTurn()
  }

  @Test("A reload without server progress keeps the stalled state")
  func quietTurnWithoutServerProgressStaysStalled() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionQuietTurnScheduler()
    client.echoOnPrompt = false
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: false,
      stopReason: "end_turn",
      eventCursor: 2,
      text: "earlier answer"
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      stalledTurnQuietInterval: .seconds(300),
      quietTurnScheduler: scheduler.scheduler
    )
    await model.loadHistoryForInitialDisplay()
    #expect(model.serverEventCursor == 2)

    await model.send("keep working")
    #expect(scheduler.callCount == 1)

    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: true,
      stopReason: nil,
      eventCursor: 2,
      text: "partial answer"
    )
    await scheduler.advance()

    #expect(model.serverEventCursor == 2)
    #expect(model.isSending)
    #expect(model.isTakingLongerThanExpected)
    model.endTurn()
  }

  @Test("Steady streaming activity keeps re-arming the quiet-turn timer")
  func steadyActivityNeverReportsStalled() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionQuietTurnScheduler()
    client.echoOnPrompt = false
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: true,
      stopReason: nil,
      eventCursor: 16
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      stalledTurnQuietInterval: .seconds(300),
      quietTurnScheduler: scheduler.scheduler
    )

    await model.send("stream steadily")
    #expect(scheduler.callCount == 1)

    for id in 1...16 {
      model.apply(
        .update(
          .agentMessageChunk(
            .text("chunk "),
            messageId: "msg-1",
            parentToolCallId: nil,
            phase: nil
          )))
      #expect(scheduler.callCount == id + 1)
      #expect(
        model.isTakingLongerThanExpected == false,
        "a steadily streaming turn must never report itself stalled (chunk \(id))"
      )
    }

    #expect(model.isSending)

    await scheduler.advance()
    await settleUntil { model.isTakingLongerThanExpected }
    model.endTurn()
  }
}
