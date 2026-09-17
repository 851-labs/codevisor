import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptInlineTextProjectionTests {
  @Test func longStreamingTextKeepsItsOriginalRendererAndIdentity() {
    let id = UUID()
    var turn = AssistantTurn(isGenerating: true)
    func append(_ text: String, offset: Int, revision: Int) {
      TranscriptReducer.apply(
        .agentMessagePatch(
          AgentMessagePatch(
            messageId: "answer", text: text, offset: offset,
            totalLength: offset + text.utf16.count, generation: 0, stateRevision: revision)), to: &turn)
    }
    append(String(repeating: "a", count: 23_990), offset: 0, revision: 1)
    let before = TranscriptActiveRowProjection.rows(for: .assistant(AssistantMessage(id: id, turn: turn)))
    append(String(repeating: "b", count: 20_000), offset: 23_990, revision: 2)
    let after = TranscriptActiveRowProjection.rows(for: .assistant(AssistantMessage(id: id, turn: turn)))
    let originalKeys = before.compactMap { row -> String? in
      if case .markdownChunk = row.content { return row.layoutKey }; return nil
    }
    let updatedKeys = after.compactMap { row -> String? in
      if case .markdownChunk = row.content { return row.layoutKey }; return nil
    }
    #expect(!originalKeys.isEmpty)
    #expect(updatedKeys == originalKeys)
    #expect(
      turn.entries == [
        .text(id: "acp:answer", markdown: String(repeating: "a", count: 23_990) + String(repeating: "b", count: 20_000))
      ])
  }
}
