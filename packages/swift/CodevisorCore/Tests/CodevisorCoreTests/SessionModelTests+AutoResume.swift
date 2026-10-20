import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("A pending auto-resume follows the history page and the server's live updates")
  func autoResumeFollowsServer() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [],
      hasMore: false,
      eventCursor: 0,
      autoResume: ServerSessionAutoResume(resumesAt: "2026-10-20T22:00:00.000Z")
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    await model.loadHistoryForInitialDisplay()
    #expect(model.autoResume == SessionAutoResume(resumesAt: Date(timeIntervalSince1970: 1_792_533_600)))

    await model.send("keep going")
    await settleUntil { !model.isSending }
    client.emit(autoResumeEvent(sessionId, id: 3, payload: ["state": .string("cleared")]))
    await settleUntil { model.autoResume == nil }

    client.emit(autoResumeEvent(sessionId, id: 4, payload: ["state": .string("scheduled")]))
    await settleUntil { model.autoResume != nil }
    #expect(model.autoResume == SessionAutoResume(resumesAt: nil))
  }

  @Test("Declining the auto-resume hides it at once and brings it back if the server refuses")
  func declineAutoResume() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [],
      hasMore: false,
      eventCursor: 0,
      autoResume: ServerSessionAutoResume()
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await model.loadHistoryForInitialDisplay()

    client.failNextAutoResumeCancel()
    #expect(!(await model.cancelAutoResume()))
    #expect(model.autoResume == SessionAutoResume())
    #expect(model.errorMessage != nil)

    #expect(await model.cancelAutoResume())
    #expect(model.autoResume == nil)
    #expect(await model.cancelAutoResume())
    #expect(client.autoResumeCancelCount == 1)
  }

  private func autoResumeEvent(
    _ sessionId: UUID,
    id: Int,
    payload: [String: JSONValue]
  ) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: id,
      serverId: "local",
      kind: "session.autoResume.updated",
      subjectId: sessionId.uuidString,
      createdAt: "2026-10-20T21:00:00.000Z",
      payload: .object(payload)
    )
  }
}
