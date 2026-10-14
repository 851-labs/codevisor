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
    #expect(turn.workedItems.isEmpty)
    TranscriptReducer.apply(.contextCompaction(id: "compact", status: status), to: &turn)
    #expect(activity(turn) == nil)
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

  @Test("An agent call being written reads as starting an agent until its input arrives, even beside running work")
  func startingAgent() {
    func activity(_ turn: AssistantTurn) -> String? {
      AssistantTurnActivity.resolve(
        turn: turn, isWaitingOnUser: false,
        sessionActivity: nil, backgroundTask: nil, goalActivity: nil)?.message
    }
    var turn = AssistantTurn(isGenerating: true)
    TranscriptReducer.apply(
      .toolCall(
        ToolCall(
          toolCallId: "running", title: "Agent", kind: .agent, status: .inProgress,
          rawInput: .object(["prompt": .string("Map the chat UI.")]))), to: &turn)
    #expect(activity(turn) == nil)

    TranscriptReducer.apply(
      .toolCall(ToolCall(toolCallId: "writing", title: "Agent", kind: .agent, status: .inProgress)), to: &turn)
    #expect(activity(turn) == "Starting agent…")

    TranscriptReducer.apply(
      .toolCallUpdate(ToolCallUpdate(toolCallId: "writing", rawInput: .object(["prompt": .string("Map the mirror.")]))),
      to: &turn)
    #expect(activity(turn) == nil)
  }

  @Test("A quiet turn has no label and a retry gives it one")
  func retryWins() {
    var turn = AssistantTurn(isGenerating: true, isThinking: false)
    #expect(
      AssistantTurnActivity.resolve(
        turn: turn, isWaitingOnUser: false,
        sessionActivity: nil, backgroundTask: nil, goalActivity: nil) == nil)
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

  @Test("Waiting chips stay in place as their agents finish, and new ones join after them")
  func waitingChipsStayPut() {
    func call(_ id: String) -> ToolCall { ToolCall(toolCallId: id, title: id, kind: .agent, status: .completed) }
    let shown = WaitingOnAgentsLine.merging([], [call("a"), call("b")])
    #expect(WaitingOnAgentsLine.merging(shown, [call("b")]).map(\.toolCallId) == ["a", "b"])
    #expect(WaitingOnAgentsLine.merging(shown, [call("c"), call("a")]).map(\.toolCallId) == ["a", "b", "c"])
  }
}
