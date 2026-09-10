import ACPKit
import CodevisorCore
import Testing
@testable import CodevisorUI

@Suite("Transcript activity priority")
struct AssistantTurnActivityTests {
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
