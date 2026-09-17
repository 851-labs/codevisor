import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptResidentWindowTests {
  @Test func longRunningTurnKeepsBoundedEntriesAndReloadIdentity() {
    var turn = AssistantTurn(isGenerating: true)
    for revision in 1...2_000 {
      TranscriptReducer.apply(
        .agentMessagePatch(
          AgentMessagePatch(
            messageId: "part-\(revision)", text: "Part \(revision)", offset: 0,
            totalLength: 10, generation: 0, stateRevision: revision, statePosition: revision
          )), to: &turn)
      turn.boundResidentEntries(itemId: "permanent-turn", limit: 32)
      #expect(turn.entries.count <= 32)
      #expect(turn.textStates.count <= 33)
    }
    #expect(turn.deferredDetailItemId == "permanent-turn")
    #expect(turn.hasDeferredWorkedDetails)
    #expect(turn.entries.last == .text(id: "acp:part-2000", markdown: "Part 2000"))
  }
}
