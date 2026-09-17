import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Loading older history retains the visible document and live work")
  func loadedHistoryAndWorkStayResident() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    func page(_ range: Range<Int>) -> ServerTranscriptPage {
      ServerTranscriptPage(
        items: range.map { sequence in
          ServerTranscriptItem(
            id: UUID().uuidString, sessionId: sessionId.uuidString, sequence: sequence,
            role: .user, text: "Message \(sequence)", createdAt: "2026-06-30T00:00:00.000Z",
            updatedAt: "2026-06-30T00:00:00.000Z", isGenerating: false,
            hasDetails: false, revision: 1)
        }, nextBefore: String(range.lowerBound), hasMore: range.lowerBound > 0,
        eventCursor: 1)
    }
    client.initialTranscriptPage = page(64..<96)
    await model.loadHistory()
    let latest = model.conversation
    client.olderTranscriptPage = page(0..<64)
    #expect(await model.loadOlderHistory() == 64)
    #expect(model.settledConversation.count == 96)
    #expect(Array(model.conversation.suffix(32)) == latest)
    #expect(!model.hasOlderHistory)
    let historyIDs = model.conversation.map(\.id)
    for index in 0..<160 {
      model.apply(.update(.toolCall(ToolCall(toolCallId: "tool-\(index)", title: "Tool \(index)", status: .completed))))
    }
    guard case let .assistant(message) = model.activeItem else { Issue.record("Missing live turn"); return }
    #expect(message.turn.toolCalls.count == 160)
    #expect(!message.turn.hasDeferredWorkedDetails)
    #expect(Array(model.conversation.prefix(96)).map(\.id) == historyIDs)
  }
}
