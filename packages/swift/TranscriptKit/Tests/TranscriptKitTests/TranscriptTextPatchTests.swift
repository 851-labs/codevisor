import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptTextPatchTests {
  @Test func restoredPlanKeepsWorkOnTheCorrectSideOfThePlan() {
    var turn = AssistantTurn(isGenerating: false)
    func text(_ id: String, position: Int, phase: MessagePhase) {
      TranscriptReducer.apply(
        .agentMessagePatch(
          AgentMessagePatch(
            messageId: id, text: id, offset: 0, totalLength: id.utf16.count,
            generation: 0, stateRevision: position, phase: phase, statePosition: position)), to: &turn)
    }
    text("answer", position: 4, phase: .final)
    text("planning", position: 1, phase: .commentary)
    TranscriptReducer.apply(.planDocument(markdown: "The plan", detailResource: nil, stateRevision: 2), to: &turn)
    text("implementation", position: 3, phase: .commentary)
    #expect(turn.workedItemsBeforePlan == [.text(id: "acp:planning", markdown: "planning")])
    #expect(turn.workedItemsAfterPlan == [.text(id: "acp:implementation", markdown: "implementation")])
  }

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

  @Test func offsetsCountUTF16AndStreamingKeepsCompleteText() {
    var turn = AssistantTurn()
    for patch in [
      AgentMessagePatch(messageId: "answer", text: "😀", offset: 0, totalLength: 2, generation: 0, stateRevision: 1),
      AgentMessagePatch(
        messageId: "answer", text: String(repeating: "a", count: 40_000), offset: 2,
        totalLength: 40_002, generation: 0, stateRevision: 2),
    ] { TranscriptReducer.apply(.agentMessagePatch(patch), to: &turn) }
    guard case let .text(_, text) = turn.entries.first else { Issue.record("Missing answer"); return }
    #expect(text.hasPrefix("😀a"))
    #expect(text.utf16.count == 40_002)
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
