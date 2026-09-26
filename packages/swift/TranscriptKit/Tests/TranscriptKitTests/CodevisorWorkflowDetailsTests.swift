import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

@Suite("Codevisor workflow details")
struct CodevisorWorkflowDetailsTests {
  private func workflow(
    status: ToolCallStatus = .completed, code: String? = "\n  async () => 42\n", rawOutput: JSONValue?
  )
    -> ToolCall
  {
    var input: [String: JSONValue] = ["description": .string("Build it")]
    if let code { input["code"] = .string(code) }
    return ToolCall(
      toolCallId: "wf", title: "mcp__codevisor__execute", kind: .other, status: status,
      rawInput: .object(input), rawOutput: rawOutput
    )
  }

  @Test("The code a workflow ran is shown trimmed")
  func code() throws {
    #expect(try #require(workflow(rawOutput: nil).codevisorWorkflowDetails).code == "async () => 42")
    #expect(ToolCall(toolCallId: "x", title: "Bash").codevisorWorkflowDetails == nil)
  }

  @Test("Without code, the result is unwrapped from Claude and Codex output shapes")
  func result() throws {
    let claude = try #require(
      workflow(
        code: nil,
        rawOutput: .array([
          .object(["type": .string("text"), "text": .string(#"{"result":{"b":2,"a":[1]},"logs":[]}"#)])
        ])
      ).codevisorWorkflowDetails)
    #expect(claude.result == "{\n  \"a\" : [\n    1\n  ],\n  \"b\" : 2\n}")

    let codex = try #require(
      workflow(
        code: nil,
        rawOutput: .object(["content": .array([.object(["text": .string(#"{"result":"done","logs":[]}"#)])])])
      ).codevisorWorkflowDetails)
    #expect(codex.result == "done")
    #expect(try #require(workflow(rawOutput: .string(#"{"result":null}"#)).codevisorWorkflowDetails).result == nil)
    #expect(try #require(workflow(rawOutput: .string("not json")).codevisorWorkflowDetails).result == "not json")
  }

  @Test("A failed workflow reports its error instead of a result")
  func failure() throws {
    let failed = try #require(
      workflow(status: .failed, rawOutput: .string("Error: boom\n    at <anonymous> (x.js:1:2)"))
        .codevisorWorkflowDetails)
    #expect(failed.failure == "boom")
    #expect(failed.result == nil)
  }
}
