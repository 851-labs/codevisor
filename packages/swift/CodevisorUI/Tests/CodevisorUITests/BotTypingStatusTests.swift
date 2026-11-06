import ACPKit
import CodevisorCore
import Testing
@testable import CodevisorUI

@Suite("Bot typing status")
struct BotTypingStatusTests {
  private func workflow(_ input: [String: JSONValue]) -> AssistantTurn {
    AssistantTurn(
      entries: [
        .tool(
          ToolCall(toolCallId: "run", title: "mcp__codevisor__execute", status: .inProgress, rawInput: .object(input)))
      ],
      isGenerating: true)
  }

  @Test("A workflow without a description keeps the previous status instead of a generic one")
  func undescribedWorkflow() {
    #expect(BotTypingStatus.activity(of: workflow(["code": "async () => 42"])) == .pending)
    #expect(
      BotTypingStatus.activity(of: workflow(["code": "async () => 42", "description": "Check the inbox"]))
        == .step("Check the inbox"))
  }
}
