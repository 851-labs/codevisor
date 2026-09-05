import Foundation
import Testing
import CodevisorTestSupport
import ACPKit
@testable import CodevisorCore

/// Flush-batch coalescing helpers on the hottest path in the app.
@MainActor
@Suite("SessionModel stream pacing")
struct SessionModelStreamPacingTests {
  private func chunk(
    _ text: String,
    messageId: String? = "m1",
    parent: String? = nil,
    phase: MessagePhase? = nil
  ) -> ServerSessionStreamEvent {
    .update(.agentMessageChunk(.text(text), messageId: messageId, parentToolCallId: parent, phase: phase))
  }

  @Test("Visible fallback flushing stays fast while hidden flushing stays coarse")
  func visibilityControlsFlushCadence() {
    #expect(
      SessionModel.flushInterval(
        isViewVisible: true,
        foreground: .milliseconds(16),
        background: .milliseconds(300)
      ) == .milliseconds(16)
    )
    #expect(
      SessionModel.flushInterval(
        isViewVisible: false,
        foreground: .milliseconds(16),
        background: .milliseconds(300)
      ) == .milliseconds(300)
    )
  }

  @Test("The fastest visible display clock exclusively drives presentation")
  func fastestDisplayClockWins() {
    let controller = SessionController.preview()
    var sixtyHertzRequests = 0
    var oneTwentyHertzRequests = 0
    let sixty = controller.registerTranscriptFrameDriver(maximumFramesPerSecond: 60) {
      sixtyHertzRequests += 1
    }
    let oneTwenty = controller.registerTranscriptFrameDriver(maximumFramesPerSecond: 120) {
      oneTwentyHertzRequests += 1
    }

    #expect(controller.requestTranscriptPresentationFrame())
    #expect(sixtyHertzRequests == 0)
    #expect(oneTwentyHertzRequests == 1)

    let revision = controller.transcriptPresentationFrameRevision
    controller.transcriptPresentationFrameDidFire(sixty)
    #expect(controller.transcriptPresentationFrameRevision == revision)
    controller.transcriptPresentationFrameDidFire(oneTwenty)
    #expect(controller.transcriptPresentationFrameRevision == revision + 1)

    #expect(controller.requestTranscriptPresentationFrame())
    controller.unregisterTranscriptFrameDriver(oneTwenty)
    #expect(sixtyHertzRequests == 1)
    controller.transcriptPresentationFrameDidFire(sixty)
    #expect(controller.transcriptPresentationFrameRevision == revision + 2)
    controller.unregisterTranscriptFrameDriver(sixty)
  }

  @Test("Stream ingress wakes once per buffered burst and rejects stale consumers")
  func eventIngressIsLatestGenerationAndSingleWakeup() {
    let buffer = SessionEventBuffer()
    let firstGeneration = buffer.beginConsumer()

    #expect(buffer.append(chunk("a"), cursor: 7, generation: firstGeneration))
    #expect(!buffer.append(chunk("b"), cursor: 8, generation: firstGeneration))
    #expect(
      buffer.takeAll() == [
        SessionPendingStreamEvent(chunk("a"), cursor: 7),
        SessionPendingStreamEvent(chunk("b"), cursor: 8),
      ])

    buffer.invalidateConsumer()
    let secondGeneration = buffer.beginConsumer()
    #expect(!buffer.append(chunk("stale"), generation: firstGeneration))
    #expect(buffer.append(chunk("current"), generation: secondGeneration))
    #expect(buffer.takeAll() == [SessionPendingStreamEvent(chunk("current"))])
  }

  @Test("A visible semantic drain waits for the display boundary")
  func semanticDrainUsesDisplayBoundary() async {
    let sessionID = UUID()
    let client = FakeSessionServerClient(sessionId: sessionID)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionID),
      sessionId: sessionID.uuidString
    )
    let clock = TestClock()
    model.presentationBoundarySleep = clock.sleep
    let generation = model.pendingEvents.beginConsumer()
    #expect(model.pendingEvents.append(chunk("frame me"), generation: generation))
    var frameRequests = 0
    model.presentationFrameRequester = {
      frameRequests += 1
      return true
    }
    model.viewDidAppear()

    let drain = Task { @MainActor in
      await model.flushPendingEventsAtPresentationBoundary()
    }
    await clock.waitForSleep(.milliseconds(1))

    #expect(frameRequests > 0)
    #expect(!model.pendingEvents.isEmpty)
    model.flushPendingEvents()
    clock.advance(by: .milliseconds(1))
    await drain.value
    #expect(model.pendingEvents.isEmpty)
    model.shutdown()
  }

  @Test("Adjacent same-span text chunks merge into one")
  func adjacentChunksMerge() {
    let merged = SessionModel.coalesced([chunk("Hel"), chunk("lo "), chunk("world")])
    #expect(merged == [chunk("Hello world")])
  }

  @Test("Chunks for different spans, parents, or phases stay separate")
  func differentTargetsDoNotMerge() {
    let events = [
      chunk("a", messageId: "m1"),
      chunk("b", messageId: "m2"),
      chunk("c", messageId: "m2", parent: "tool-1"),
      chunk("d", messageId: "m2", parent: "tool-1", phase: .commentary),
    ]
    #expect(SessionModel.coalesced(events) == events)
  }

  @Test("Zero-length retro-tag chunks never merge")
  func retroTagChunksStaySeparate() {
    let events = [chunk("preamble"), chunk("", phase: .commentary), chunk("answer")]
    #expect(SessionModel.coalesced(events) == events)
  }

  @Test("Non-text events break a merge run and are preserved in order")
  func nonTextEventsPreserved() {
    let finished = ServerSessionStreamEvent.finished(.endTurn, stopDetail: nil)
    let events = [chunk("a"), chunk("b"), finished, chunk("c"), chunk("d")]
    #expect(SessionModel.coalesced(events) == [chunk("ab"), finished, chunk("cd")])
  }

  @Test("Coalescing merged chunks applies identically to applying them singly")
  func mergePreservesReducedTranscript() {
    var merged = AssistantTurn()
    var single = AssistantTurn()
    let updates: [SessionUpdate] = [
      .agentMessageChunk(.text("Hello "), messageId: "m1", parentToolCallId: nil, phase: nil),
      .agentMessageChunk(.text("world"), messageId: "m1", parentToolCallId: nil, phase: nil),
    ]
    for update in updates {
      TranscriptReducer.apply(update, to: &single)
    }
    for case let .update(update) in SessionModel.coalesced(updates.map { .update($0) }) {
      TranscriptReducer.apply(update, to: &merged)
    }
    #expect(merged.entries == single.entries)
  }

}
