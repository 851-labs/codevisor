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

  @Test("The result is unwrapped from Claude and Codex output shapes")
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
    #expect(ToolCall(toolCallId: "x", title: "Bash").codevisorWorkflowDetails == nil)
  }

  @Test("A failed workflow reports its error instead of a result")
  func failure() throws {
    let failed = try #require(
      workflow(status: .failed, rawOutput: .string("Error: boom\n    at <anonymous> (x.js:1:2)"))
        .codevisorWorkflowDetails)
    #expect(failed.failure == "boom")
    #expect(failed.result == nil)
  }

  @Test("Files the workflow produced are shown once each")
  func files() throws {
    var call = workflow(rawOutput: .string(#"{"result":"ok"}"#))
    call.meta = [
      "codevisorExecution": [
        "state": "completed",
        "calls": [
          [
            "path": "browser.screenshot", "ok": true,
            "files": [
              ["fileId": "f1", "name": "shot.png", "mimeType": "image/png"],
              ["fileId": "f2", "name": "clip.mp4", "mimeType": "video/mp4"],
              ["name": "no id"],
            ],
          ],
          ["path": "browser.screenshot", "ok": true, "files": [["fileId": "f1", "name": "shot.png"]]],
        ],
      ]
    ]
    let details = try #require(call.codevisorWorkflowDetails)
    #expect(details.files.map(\.name) == ["shot.png", "clip.mp4"])
    #expect(details.files.map(\.kind) == [.image, .file])
  }

  @Test("A script's stringified results are unpacked, without the file references shown above them")
  func cleanedResult() throws {
    // Codex returned its browser cells' results as JSON strings.
    let returned: JSONValue = [
      #"{"value":"Page URL: https://news.ycombinator.com/","artifacts":[{"type":"artifact_ref","fileId":"f1"}]}"#,
      #"[{"title":"Cloudflare acquires Deno","points":1116}]"#,
      .null,
    ]
    let encoded = try #require(
      String(data: JSONEncoder().encode(JSONValue.object(["result": returned])), encoding: .utf8))
    let details = try #require(workflow(rawOutput: .string(encoded)).codevisorWorkflowDetails)
    #expect(
      details.result == """
        [
          "Page URL: https://news.ycombinator.com/",
          [
            {
              "points" : 1116,
              "title" : "Cloudflare acquires Deno"
            }
          ]
        ]
        """)
    // A result that was only a file reference leaves nothing to show.
    let onlyFile = try #require(
      workflow(rawOutput: .string(#"{"result":{"fileId":"f1","name":"shot.png"}}"#)).codevisorWorkflowDetails)
    #expect(onlyFile.result == nil)
  }
}
