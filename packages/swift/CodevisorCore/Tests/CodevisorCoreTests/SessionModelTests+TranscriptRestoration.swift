import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test(
    "Mid-stream restore keeps an unclassified answer candidate optimistic and preserves provider-asserted finality",
    arguments: [(MessagePhase?.none, false), (MessagePhase.final, true)])
  func midStreamRestoreKeepsUnknownPhaseOptimistic(phase: MessagePhase?, asserted: Bool) {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let transport = ServerSessionTransport(client: client, sessionId: sessionId)
    let page = transport.historyPage(
      from: ServerTranscriptPage(
        items: [
          ServerTranscriptItem(
            id: UUID().uuidString,
            sessionId: sessionId.uuidString,
            sequence: 0,
            role: .assistant,
            text: "The answer candidate is streaming.",
            createdAt: "2026-07-18T00:00:00.000Z",
            updatedAt: "2026-07-18T00:00:01.000Z",
            isGenerating: true,
            hasDetails: true,
            messageId: "msg-optimistic",
            phase: phase,
            revision: 2
          )
        ],
        hasMore: false,
        eventCursor: 2
      ))

    guard case let .assistant(message) = page.conversation.last else {
      Issue.record("expected restored assistant")
      return
    }
    #expect(message.turn.isGenerating)
    #expect(message.turn.finalTextIsAsserted == asserted)
    guard case let .text(id, markdown) = message.turn.finalText else {
      Issue.record("expected restored text")
      return
    }
    #expect(id == "acp:msg-optimistic")
    #expect(markdown == "The answer candidate is streaming.")
  }
}
