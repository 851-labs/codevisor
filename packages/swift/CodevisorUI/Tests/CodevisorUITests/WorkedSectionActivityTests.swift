import ACPKit
import CodevisorCore
import Testing
@testable import CodevisorUI

@Suite("Live worked header label")
struct WorkedSectionActivityTests {
  @Test("The label names the current step without a trailing ellipsis")
  func labels() {
    var turn = AssistantTurn(isGenerating: true, isThinking: true)
    #expect(turn.workedSectionActivity == "Thinking")

    turn.isThinking = false
    turn.entries = [.tool(ToolCall(toolCallId: "edit", title: "Edit", kind: .edit, status: .inProgress))]
    #expect(turn.workedSectionActivity == "Editing file")

    turn.entries = [.tool(ToolCall(toolCallId: "ls", title: "Ran ls", kind: .execute, status: .completed))]
    // Between tool calls the model is deciding its next step.
    #expect(turn.workedSectionActivity == "Thinking")

    turn.entries.append(.text(id: "answer", markdown: "Done."))
    // While the answer streams the header reads "Worked for", unlabeled.
    #expect(turn.workedSectionActivity == nil)
  }
}
