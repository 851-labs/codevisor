import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptTextPatchTests {
  @Test func overlappingSnapshotAndLiveTextConverge() {
    let prefix = AgentMessagePatch(
      messageId: "answer", text: "hello", offset: 0,
      totalLength: 5, generation: 0, stateRevision: 1)
    let continuation = AgentMessagePatch(
      messageId: "answer", text: " world", offset: 5,
      totalLength: 11, generation: 0, stateRevision: 2)
    let snapshot = AgentMessagePatch(
      messageId: "answer", text: "hello world", offset: 0,
      totalLength: 11, generation: 0, stateRevision: 2)
    for updates in [[prefix, continuation, snapshot], [prefix, snapshot, continuation]] {
      var turn = AssistantTurn()
      for update in updates { TranscriptReducer.apply(.agentMessagePatch(update), to: &turn) }
      #expect(turn.entries == [.text(id: "acp:answer", markdown: "hello world")])
    }
  }

  @Test func latePageCannotUndoFinalizedTextOrPhase() {
    var turn = AssistantTurn()
    let old = AgentMessagePatch(
      messageId: "answer", text: "draft", offset: 0,
      totalLength: 5, generation: 0, stateRevision: 1, phase: .commentary)
    let final = AgentMessagePatch(
      messageId: "answer", text: "final", offset: 0,
      totalLength: 5, generation: 1, stateRevision: 2, phase: .final)
    for update in [old, final, old] { TranscriptReducer.apply(.agentMessagePatch(update), to: &turn) }
    #expect(turn.entries == [.text(id: "acp:answer", markdown: "final")])
    #expect(turn.textPhases["acp:answer"] == .final)
  }

  @Test func offsetsCountUTF16AndPreviewsStayBounded() {
    var turn = AssistantTurn()
    for patch in [
      AgentMessagePatch(messageId: "answer", text: "😀", offset: 0, totalLength: 2, generation: 0, stateRevision: 1),
      AgentMessagePatch(
        messageId: "answer", text: String(repeating: "a", count: 40_000), offset: 2,
        totalLength: 40_002, generation: 0, stateRevision: 2),
    ] { TranscriptReducer.apply(.agentMessagePatch(patch), to: &turn) }
    guard case let .text(_, text) = turn.entries.first else { Issue.record("Missing answer"); return }
    #expect(text.hasPrefix("😀a"))
    #expect(text.utf16.count == 24_000)
  }

  @Test func olderToolSnapshotCannotReopenCompletedTool() throws {
    let decoder = JSONDecoder()
    let old = try decoder.decode(
      ToolCall.self,
      from: Data(
        #"{"toolCallId":"read","title":"Read","status":"in_progress","isSnapshot":true,"stateRevision":1}"#.utf8))
    let current = try decoder.decode(
      ToolCall.self,
      from: Data(#"{"toolCallId":"read","title":"Read","status":"completed","isSnapshot":true,"stateRevision":2}"#.utf8)
    )
    var turn = AssistantTurn()
    for call in [old, current, old] { TranscriptReducer.apply(.toolCall(call), to: &turn) }
    #expect(turn.entries == [.tool(current)])
  }
}
