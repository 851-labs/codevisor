import ACPKit
import CodevisorCore
import Testing
@testable import CodevisorUI

@Suite("Transcript activity priority")
struct AssistantTurnActivityTests {
  @Test(
    "Compaction is temporary activity and clears on completion or failure",
    arguments: [ContextCompactionStatus.completed, .failed])
  func compactionLifecycle(status: ContextCompactionStatus) {
    var turn = AssistantTurn(isGenerating: true, isThinking: true)
    func activity(_ turn: AssistantTurn) -> String? {
      AssistantTurnActivity.resolve(
        turn: turn, isWaitingOnUser: false,
        sessionActivity: nil, backgroundTask: nil, goalActivity: nil)?.message
    }
    #expect(activity(turn) == "Thinking…")
    TranscriptReducer.apply(.contextCompaction(id: "compact", status: .started), to: &turn)
    #expect(activity(turn) == "Compacting context…")
    #expect(turn.streamingItems.isEmpty)
    TranscriptReducer.apply(.contextCompaction(id: "compact", status: status), to: &turn)
    #expect(activity(turn) == "Waiting on harness...")
    #expect(turn.workedItems.isEmpty)
    TranscriptReducer.apply(.agentThoughtChunk(.text("next step")), to: &turn)
    #expect(activity(turn) == "Thinking…")
    TranscriptReducer.apply(.contextCompaction(id: "next", status: .started), to: &turn)
    #expect(activity(turn) == "Compacting context…")
    turn.isGenerating = false
    #expect(activity(turn) == nil)
  }

  @Test("Session recovery replaces every turn activity, including retry and compaction")
  func recoveryWins() {
    var turn = AssistantTurn(isGenerating: true, isThinking: true)
    turn.entries.append(.contextCompaction(id: "compaction", status: .started))
    turn.retryStatus = RetryStatus(attempt: 1, of: 3, message: "Retrying")
    for label in ["Reconnecting…", "Catching up…", "Waiting for Codex to finish updating..."] {
      #expect(
        AssistantTurnActivity.resolve(
          turn: turn, isWaitingOnUser: false,
          sessionActivity: label, backgroundTask: "build", goalActivity: .verifying) == nil)
    }
  }

  @Test("A quiet turn has one waiting label and a retry replaces it")
  func retryWins() {
    var turn = AssistantTurn(isGenerating: true, isThinking: false)
    #expect(
      AssistantTurnActivity.resolve(
        turn: turn, isWaitingOnUser: false,
        sessionActivity: nil, backgroundTask: nil, goalActivity: nil)?.message == "Waiting on harness...")
    turn.retryStatus = RetryStatus(attempt: 2, of: 3, message: "Retrying")
    #expect(
      AssistantTurnActivity.resolve(
        turn: turn, isWaitingOnUser: false,
        sessionActivity: nil, backgroundTask: nil, goalActivity: nil)?.message == "Retrying 2/3")
    #expect(
      AssistantTurnActivity.resolve(
        turn: turn, isWaitingOnUser: true,
        sessionActivity: nil, backgroundTask: nil, goalActivity: nil) == nil)
  }
}
