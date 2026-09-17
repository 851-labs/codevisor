import Foundation
import CodevisorTestSupport
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Reopening an active chat restores its latest work automatically without blocking live updates")
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
    await client.transcriptDetailRequests.wait()
    #expect(client.transcriptDetailCursors == [nil])
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
    await awaitObserved {
      guard case let .assistant(message) = model.activeItem else { return false }
      return message.turn.hasHydratedWorkedDetails
    }

    guard case let .assistant(hydratedMessage) = model.activeItem else {
      Issue.record("expected hydrated active assistant")
      return
    }
    #expect(hydratedMessage.turn.hasHydratedWorkedDetails)
    #expect(hydratedMessage.turn.isGenerating)
    #expect(hydratedMessage.turn.startedAt == compactMessage.turn.startedAt)
    #expect(Set(hydratedMessage.turn.toolCalls.map(\.toolCallId)) == ["tool-before-open", "tool-after-open"])
    #expect(client.transcriptDetailRequestCount == 1)
    #expect(!hydratedMessage.turn.isThinking)
    model.shutdown()
  }
}
