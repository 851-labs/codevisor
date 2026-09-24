import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("History refresh preserves echoed user identity and the durable starting response")
  func startupHistoryPreservesUserIdentityAndWaiting() async throws {
    let sessionID = UUID()
    let client = FakeSessionServerClient(sessionId: sessionID)
    client.echoOnPrompt = false
    let transport = ServerSessionTransport(client: client, sessionId: sessionID)
    let model = SessionModel(serverTransport: transport, sessionId: sessionID.uuidString)
    defer { model.shutdown() }
    let outgoing = UserMessage(text: "Send me a couple code blocks in your response.")
    await model.send(outgoing)
    model.apply(.userMessage(id: outgoing.id.uuidString, text: outgoing.text, attachments: []))
    #expect(model.pendingOptimisticUserMessageIDs.isEmpty)

    let assistantID = UUID()
    let page = try JSONDecoder().decode(
      ServerTranscriptPage.self,
      from: Data(
        """
        {
          "items": [
            {
              "id": "\(UUID())", "messageId": "\(outgoing.id)",
              "sessionId": "\(sessionID)", "sequence": 0, "role": "user",
              "text": "\(outgoing.text)", "isGenerating": false, "hasDetails": false,
              "createdAt": "2026-09-16T20:16:13.000Z", "updatedAt": "2026-09-16T20:16:13.000Z",
              "revision": 1
            },
            {
              "id": "\(assistantID)", "sessionId": "\(sessionID)", "sequence": 1,
              "role": "assistant", "text": "", "isGenerating": true, "hasDetails": false,
              "createdAt": "2026-09-16T20:16:13.000Z", "updatedAt": "2026-09-16T20:16:13.000Z",
              "revision": 1
            }
          ], "setupActivities": [], "stateUpdates": [], "hasNewer": false, "hasMore": false, "eventCursor": 3
        }
        """.utf8))

    await model.loadHistoryForInitialDisplay(preloaded: transport.historyPage(from: page))

    #expect(model.conversation.map(\.id) == [outgoing.id, assistantID])
    #expect(model.isSending)
    guard case let .assistant(waiting) = model.conversation.last else {
      Issue.record("Expected the durable waiting response")
      return
    }
    #expect(waiting.turn.isGenerating)
    model.apply(.assistantItemStarted(assistantID))
    #expect(model.conversation.map(\.id) == [outgoing.id, assistantID])
  }

  @Test("Legacy history keeps distinct client IDs for identical user text")
  func legacyHistoryPreservesDistinctUserMessageIDs() async {
    let sessionID = UUID()
    let firstID = UUID()
    let secondID = UUID()
    let fallbackID = UUID()
    let client = FakeSessionServerClient(sessionId: sessionID)
    let rows = [
      (UUID(), firstID.uuidString), (UUID(), secondID.uuidString), (fallbackID, "legacy-non-uuid"),
    ]
    client.initialTranscriptPage = ServerTranscriptPage(
      items: rows.enumerated().map { index, row in
        ServerTranscriptItem(
          id: row.0.uuidString, sessionId: sessionID.uuidString, sequence: index, role: .user,
          text: "Again", createdAt: "2026-09-16T20:16:13.000Z", updatedAt: "2026-09-16T20:16:13.000Z",
          isGenerating: false, hasDetails: false, messageId: row.1, revision: 1)
      }, hasMore: false, eventCursor: 0)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionID),
      sessionId: sessionID.uuidString)
    defer { model.shutdown() }

    await model.loadHistoryForInitialDisplay()

    #expect(model.conversation.map(\.id) == [firstID, secondID, fallbackID])
  }
}
