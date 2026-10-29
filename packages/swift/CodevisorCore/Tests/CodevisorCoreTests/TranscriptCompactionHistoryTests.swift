import Foundation
import Testing
import TranscriptKit

@testable import CodevisorClient
@testable import CodevisorCore

@MainActor
struct TranscriptCompactionHistoryTests {
  @Test("A history turn that only compacted shows as compacted without fetching its details")
  func compactionOnlyTurnFromHistory() throws {
    let sessionID = UUID()
    let transport = ServerSessionTransport(client: FakeSessionServerClient(sessionId: sessionID), sessionId: sessionID)
    let page = try JSONDecoder().decode(
      ServerTranscriptPage.self,
      from: Data(
        """
        {
          "items": [{
            "id": "\(UUID().uuidString)", "sessionId": "\(sessionID.uuidString)", "sequence": 0,
            "role": "assistant", "text": "", "createdAt": "2026-10-29T18:50:13.137Z",
            "updatedAt": "2026-10-29T18:50:14.526Z", "isGenerating": false, "hasDetails": true,
            "stopReason": "end_turn", "compaction": "completed", "revision": 4
          }],
          "setupActivities": [], "stateUpdates": [], "hasNewer": false, "hasMore": false, "eventCursor": 1
        }
        """.utf8))

    let turns = transport.historyPage(from: page).conversation.compactMap { item -> AssistantTurn? in
      if case let .assistant(message) = item { message.turn } else { nil }
    }

    #expect(turns.map(\.compactedContext) == [true])
    #expect(turns.map(\.hasDeferredWorkedDetails) == [false])
  }
}
