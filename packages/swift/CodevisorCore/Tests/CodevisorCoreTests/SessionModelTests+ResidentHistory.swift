import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Forward paging stays bounded and jumping to latest uses one snapshot request")
  func newerHistoryWindowAndLatestJump() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    func page(_ range: Range<Int>, hasNewer: Bool) -> ServerTranscriptPage {
      var result = ServerTranscriptPage(
        items: range.map { sequence in
          ServerTranscriptItem(
            id: UUID().uuidString, sessionId: sessionId.uuidString, sequence: sequence,
            role: .user, text: "Message \(sequence)", createdAt: "2026-06-30T00:00:00.000Z",
            updatedAt: "2026-06-30T00:00:00.000Z", isGenerating: false,
            hasDetails: false, revision: 1)
        }, nextBefore: String(range.lowerBound), hasMore: range.lowerBound > 0,
        eventCursor: 1)
      result.hasNewer = hasNewer
      return result
    }
    client.initialTranscriptPage = page(0..<64, hasNewer: false)
    await model.loadHistory()
    model.hasNewerHistory = true
    client.olderTranscriptPage = page(64..<80, hasNewer: true)
    #expect(await model.loadNewerHistory() == 16)
    #expect(model.settledConversation.count == 64)
    #expect(model.transcriptSequences.values.min() == 16)
    #expect(model.transcriptSequences.values.max() == 79)
    #expect(client.transcriptPageRequests.last?.before == "after:63")
    #expect(model.hasNewerHistory && model.hasOlderHistory)

    client.initialTranscriptPage = page(10000..<10016, hasNewer: false)
    let beforeJump = client.transcriptPageRequests.count
    #expect(await model.loadNewerHistory(latest: true) == 16)
    #expect(client.transcriptPageRequests.count == beforeJump + 1)
    #expect(client.transcriptPageRequests.last?.before == nil)
    #expect(model.settledConversation.count == 16)
    #expect(model.transcriptSequences.values.min() == 10000)
    #expect(!model.hasNewerHistory && model.hasOlderHistory)
    #expect(model.olderHistoryCursor == "10000")
  }
}
