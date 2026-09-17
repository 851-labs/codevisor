import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

/// Quiet-turn (stall) detection: the timer that arms per activity event,
/// the durable-history reload it triggers, and when that reload keeps or
/// clears the "taking longer than expected" state.
extension SessionModelTests {
  @Test("Quiet turns surface a non-destructive stalled state")
  func quietTurnSurfacesStalledState() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionQuietTurnScheduler()
    client.echoOnPrompt = false
    // The stall's automatic reconcile re-reads durable history; a page
    // still reporting a live turn must leave the stalled state intact.
    // Non-empty text so the reloaded item is streaming, not "thinking",
    // matching the placeholder it replaces.
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
    // The stall consulted durable history instead of only flagging.
    #expect(client.transcriptPageRequests.count >= 1)

    #expect(model.isSending)
    #expect(model.providerActivityPhase == .modelStream)
    guard case let .assistant(message) = model.conversation.last else {
      Issue.record("expected assistant")
      return
    }
    #expect(message.turn.isThinking == false)
    client.emit(stopEnvelope(id: 10, sessionId: sessionId, stopReason: "end_turn"))
    await settleUntil { !model.isSending }
    #expect(model.isTakingLongerThanExpected == false)
    #expect(model.providerActivityPhase == nil)
  }

  /// The quiet-turn timer measures client-observed silence, which a
  /// suspended app (phone in a pocket, closed lid) produces just as well as
  /// a hung provider. The stall's reload is what tells them apart: a server
  /// cursor that moved while this client was away proves the turn is
  /// healthy, so a normal reconnect must not surface the stall notice.
  @Test("A reload that shows server progress clears the stalled state")
  func quietTurnWithServerProgressIsNotStalled() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionQuietTurnScheduler()
    client.echoOnPrompt = false
    // Seed the cursor the way a connected chat has one before sending.
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
    await model.loadHistory()
    #expect(model.serverEventCursor == 2)

    await model.send("keep working while I am away")
    #expect(scheduler.callCount == 1)

    // While the client heard nothing, the server kept producing events:
    // the durable page is still live and its cursor moved past ours.
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: true,
      stopReason: nil,
      eventCursor: 7,
      text: "partial answer"
    )
    let requestsBeforeStall = client.transcriptPageRequests.count
    await scheduler.advance()

    // The stall still consulted durable history and re-armed a fresh
    // quiet window, but a turn that made progress is not stalled.
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
    await model.loadHistory()
    #expect(model.serverEventCursor == 2)

    await model.send("keep working")
    #expect(scheduler.callCount == 1)

    // Still live on the server, but no event has landed since we last
    // heard from it: quiet on both ends is a real stall.
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

  /// Regression guard for the observable-write guards in
  /// `noteProviderActivity`. Those two writes are guarded so streaming stops
  /// re-rendering the composer on every chunk — but the quiet-turn timer
  /// underneath them must still be cancelled and re-armed per event. Guarding
  /// the whole function on a phase change instead (the obvious refactor)
  /// leaves the task armed by the FIRST chunk of a phase, so a turn that
  /// streams steadily under one phase reports itself stalled mid-stream.
  ///
  /// A manual sleeper keeps this about timer generations rather than runner
  /// scheduling: every chunk must replace the pending wait, and only the
  /// final generation is allowed to complete.

  @Test("Steady same-phase activity keeps re-arming the quiet-turn timer")
  func steadyActivityNeverReportsStalled() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionQuietTurnScheduler()
    client.echoOnPrompt = false
    // Durable history for the stall's automatic reconcile: still live, so
    // the stalled state must survive the reload. The cursor covers every
    // chunk pumped below, exactly as a freshly fetched page would.
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

    // `send` itself notes .modelStream activity, arming the first window.
    await model.send("stream steadily")
    #expect(scheduler.callCount == 1)

    // Apply chunks under the SAME phase. Each one must cancel the current
    // sleep and arm a new generation even though the observable phase does
    // not change.
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
    #expect(model.providerActivityPhase == .modelStream)

    // Only the latest timer generation is allowed to declare the turn
    // quiet. No wall-clock duration is involved.
    await scheduler.advance()
    await settleUntil { model.isTakingLongerThanExpected }
    model.endTurn()
  }
}
