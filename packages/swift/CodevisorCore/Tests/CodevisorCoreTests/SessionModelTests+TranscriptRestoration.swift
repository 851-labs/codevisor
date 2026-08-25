import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
    @Test("Mid-stream restore keeps an unclassified answer candidate optimistic")
    func midStreamRestoreKeepsUnknownPhaseOptimistic() {
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
        #expect(!message.turn.finalTextIsAsserted)
        guard case let .text(id, markdown) = message.turn.finalText else {
            Issue.record("expected restored text")
            return
        }
        #expect(id == "acp:msg-optimistic")
        #expect(markdown == "The answer candidate is streaming.")
    }

    @Test("Mid-stream restore preserves provider-asserted finality")
    func midStreamRestorePreservesFinalPhase() {
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
                        text: "The final answer is streaming.",
                        createdAt: "2026-07-18T00:00:00.000Z",
                        updatedAt: "2026-07-18T00:00:01.000Z",
                        isGenerating: true,
                        hasDetails: true,
                        messageId: "msg-final",
                        phase: .final,
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
        #expect(message.turn.finalTextIsAsserted)
    }
}
