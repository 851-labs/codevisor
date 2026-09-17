import Foundation
import CodevisorTestSupport
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Opening a chat starts live updates before its deferred details are requested")
  func activeTurnHydrationPreservesSnapshotBoundary() async {
    let sessionId = UUID()
    let assistantId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [
        ServerTranscriptItem(
          id: assistantId.uuidString,
          sessionId: sessionId.uuidString,
          sequence: 0,
          role: .assistant,
          text: "",
          createdAt: "2026-08-31T00:00:00.000Z",
          updatedAt: "2026-08-31T00:00:02.000Z",
          isGenerating: true,
          hasDetails: true,
          turnId: "remote-turn",
          startedAt: "2026-08-31T00:00:00.000Z",
          endedAt: nil,
          stopReason: nil,
          stopDetail: nil,
          planDocument: nil,
          attachments: nil,
          revision: 2
        )
      ],
      hasMore: false,
      eventCursor: 2
    )
    client.transcriptDetailsByItem[assistantId.uuidString] = ServerTranscriptItemDetails(
      itemId: assistantId.uuidString, revision: 2, eventCursor: 2,
      entries: [
        ServerTranscriptEntry(
          key: "tool:tool-before-open", position: 2, revision: 2,
          payload: .object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("tool-before-open"),
            "title": .string("Read existing state"), "isSnapshot": .bool(true), "stateRevision": .number(2),
          ]))
      ])
    let (detailGate, releaseDetails) = AsyncStream.makeStream(of: Void.self)
    client.holdTranscriptDetails(until: detailGate)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    defer { model.shutdown(); releaseDetails.finish() }
    await model.loadHistoryForInitialDisplay()
    #expect(client.transcriptDetailRequestCount == 0)
    let hydrate = Task { await model.loadTranscriptDetails(itemId: assistantId.uuidString) }
    await client.transcriptDetailRequests.wait()
    await client.eventReads.wait()
    client.emit(
      ServerEventEnvelope(
        id: 3,
        subjectRevision: 3,
        serverId: "local",
        kind: "session.output",
        subjectId: sessionId.uuidString,
        createdAt: "2026-08-31T00:00:03.000Z",
        payload: .object([
          "sessionUpdate": .string("tool_call"),
          "toolCallId": .string("tool-after-open"),
          "title": .string("Inspect live state"),
          "stateRevision": .number(3),
        ])
      ))
    await client.eventReads.wait(for: 2)

    guard case let .assistant(compactMessage) = model.activeItem else {
      Issue.record("expected compact active assistant")
      return
    }
    await awaitObserved {
      guard case let .assistant(message) = model.activeItem else { return false }
      return message.turn.toolCalls.contains { $0.toolCallId == "tool-after-open" }
    }
    #expect(compactMessage.turn.isGenerating)

    releaseDetails.yield()
    releaseDetails.finish()
    #expect(await hydrate.value)

    guard case let .assistant(hydratedMessage) = model.activeItem else {
      Issue.record("expected hydrated active assistant")
      return
    }
    #expect(hydratedMessage.turn.hasHydratedWorkedDetails)
    #expect(await hydrate.value)
    model.shutdown()
  }
}
