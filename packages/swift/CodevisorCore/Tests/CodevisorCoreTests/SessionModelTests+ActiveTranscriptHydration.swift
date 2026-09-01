import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
    @Test("A client joining an active turn hydrates worked details before newer live events")
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
            itemId: assistantId.uuidString,
            revision: 2,
            events: [
                ServerEventEnvelope(
                    id: 2,
                    subjectRevision: 2,
                    serverId: "local",
                    kind: "session.output",
                    subjectId: sessionId.uuidString,
                    createdAt: "2026-08-31T00:00:02.000Z",
                    payload: .object([
                        "sessionUpdate": .string("tool_call"),
                        "toolCallId": .string("tool-before-open"),
                        "title": .string("Read existing state"),
                    ])
                ),
                // Older servers may ignore the additive `through` query and
                // return their current item state. The transport still clips
                // the response locally to the page cursor.
                ServerEventEnvelope(
                    id: 4,
                    subjectRevision: 4,
                    serverId: "local",
                    kind: "session.output",
                    subjectId: sessionId.uuidString,
                    createdAt: "2026-08-31T00:00:04.000Z",
                    payload: .object([
                        "sessionUpdate": .string("tool_call"),
                        "toolCallId": .string("tool-beyond-snapshot"),
                        "title": .string("Must arrive through the live stream"),
                    ])
                ),
            ]
        )
        let (detailGate, releaseDetails) = AsyncStream.makeStream(of: Void.self)
        client.holdTranscriptDetails(until: detailGate)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistoryForInitialDisplay()
        await settleUntil {
            client.transcriptDetailRequestCount == 1
                && client.sessionEventSinceValues == [2]
        }
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
                ])
            ))
        await Task.yield()

        guard case let .assistant(compactMessage) = model.activeItem else {
            Issue.record("expected compact active assistant")
            return
        }
        #expect(compactMessage.turn.allToolCalls.isEmpty)

        releaseDetails.yield()
        releaseDetails.finish()
        await settleUntil {
            guard case let .assistant(message) = model.activeItem else { return false }
            return Set(message.turn.allToolCalls.map(\.toolCallId))
                == ["tool-before-open", "tool-after-open"]
        }

        guard case let .assistant(hydratedMessage) = model.activeItem else {
            Issue.record("expected hydrated active assistant")
            return
        }
        #expect(hydratedMessage.turn.hasHydratedWorkedDetails)
        #expect(client.transcriptDetailThroughRevisions == [2])
    }
}
