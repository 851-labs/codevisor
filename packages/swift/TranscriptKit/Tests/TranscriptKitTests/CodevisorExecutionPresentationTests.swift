import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

@Suite("Codevisor gateway execution presentation")
struct CodevisorExecutionPresentationTests {
  /// The server's tool snapshot, as `session-events.ts` publishes it.
  private func snapshot(status: String, execution: String) throws -> ToolCall {
    let json = """
      {"toolCallId":"call","title":"mcp__codevisor__execute","status":"\(status)","isSnapshot":true,
       "rawInput":{"description":"Build on the MacBook","code":"async () => 1"},
       "_meta":{"harness":{"x":1},"codevisorExecution":\(execution)}}
      """
    return try JSONDecoder().decode(ToolCall.self, from: Data(json.utf8))
  }

  @Test("A running workflow's one line shows its latest status, then settles to its description")
  func runningTitle() throws {
    let narrated = try snapshot(
      status: "in_progress",
      execution: #"{"state":"running","status":"Building Codevisor","calls":[]}"#
    )
    #expect(narrated.displayTitle == "Building Codevisor")

    let silent = try snapshot(
      status: "in_progress",
      execution: #"{"state":"running","status":" ","calls":[{"path":"xcode.build","ok":true,"ms":9}]}"#
    )
    #expect(silent.displayTitle == "Build on the MacBook")

    let settled = try snapshot(
      status: "completed",
      execution: #"{"state":"completed","status":"Done","calls":[]}"#
    )
    #expect(settled.displayTitle == "Build on the MacBook")
  }

  @Test("OpenCode's Code Mode row reads as the workflow it ran, and stays plain otherwise")
  func codeModeRow() throws {
    func row(status: String, meta: String) throws -> ToolCall {
      let json = """
        {"toolCallId":"oc","title":"execute","status":"\(status)","isSnapshot":true,
         "rawInput":{"code":"await tools.codevisor.execute({ description, code })"}\(meta)}
        """
      return try JSONDecoder().decode(ToolCall.self, from: Data(json.utf8))
    }
    let running = try row(
      status: "in_progress",
      meta:
        #","_meta":{"codevisorExecution":{"state":"running","description":"List my machines","status":"Asking the fleet","calls":[]}}"#
    )
    #expect(running.isIntegrationPresentationCall)
    #expect(running.displayTitle == "Asking the fleet")
    let done = try row(
      status: "completed",
      meta: #","_meta":{"codevisorExecution":{"state":"completed","description":"List my machines","calls":[]}}"#
    )
    #expect(done.displayTitle == "List my machines")
    let failed = try row(
      status: "completed",
      meta:
        #","_meta":{"codevisorExecution":{"state":"failed","description":"List my machines","calls":[],"error":"Error: no machines"}}"#
    )
    #expect(failed.displayTitle == "List my machines — failed: no machines")
    // A skill read from inside OpenCode's code reads as one.
    let skill = try row(status: "completed", meta: #","_meta":{"codevisorSkill":{"name":"execute","ok":true}}"#)
    #expect(skill.isIntegrationPresentationCall)
    #expect(skill.displayTitle == "Read the execute skill")
    let reading = try row(status: "in_progress", meta: #","_meta":{"codevisorSkill":{"name":"deploy","ok":true}}"#)
    #expect(reading.displayTitle == "Reading the deploy skill…")
    let missing = try row(status: "completed", meta: #","_meta":{"codevisorSkill":{"name":"nope","ok":false}}"#)
    #expect(missing.displayTitle == "Couldn’t read the nope skill")
    let listed = try row(status: "completed", meta: #","_meta":{"codevisorSkill":{"ok":true}}"#)
    #expect(listed.displayTitle == "Listed skills")
    // A workflow it ran says more than a skill it read first.
    let both = try row(
      status: "completed",
      meta:
        #","_meta":{"codevisorSkill":{"name":"execute","ok":true},"codevisorExecution":{"state":"completed","description":"List my machines","calls":[]}}"#
    )
    #expect(both.displayTitle == "List my machines")
    // Code that never reached the gateway is OpenCode's own tool.
    let plain = try row(status: "completed", meta: "")
    #expect(!plain.isIntegrationPresentationCall)
    #expect(plain.codevisorExecution == nil)
  }

  @Test("A failed workflow names the error's message without its stack")
  func failedTitle() throws {
    let failed = try snapshot(
      status: "failed",
      execution:
        #"{"state":"failed","calls":[],"error":"Error: codevisor.sessions.get does not accept `id` at <anonymous> (codevisor-code-executor.js:45:187) at toError (file:///x.js:1:1)"}"#
    )
    #expect(failed.displayTitle == "Build on the MacBook — failed: codevisor.sessions.get does not accept `id`")
  }

  @Test("A long or multi-line description is cut to one short label")
  func longDescription() {
    let long = ToolCall(
      toolCallId: "t",
      title: "mcp__codevisor__execute",
      rawInput: .object(["description": .string(String(repeating: "a", count: 120)), "code": .string("1")])
    )
    #expect(long.integrationDescription?.count == 80)
    #expect(long.integrationDescription?.hasSuffix("…") == true)
    let multiline = ToolCall(
      toolCallId: "t",
      title: "mcp__codevisor__execute",
      rawInput: .object(["description": .string("Checking CI\nthen more"), "code": .string("1")])
    )
    #expect(multiline.integrationDescription == "Checking CI")
  }

  @Test("Execution state only applies to gateway workflows")
  func onlyGatewayRows() {
    let meta: JSONValue = ["codevisorExecution": ["state": "running", "status": "Busy", "calls": []]]
    #expect(ToolCall(toolCallId: "t", title: "Bash", status: .inProgress, meta: meta).codevisorExecution == nil)
    #expect(
      ToolCall(toolCallId: "t", title: "codevisor.execute", status: .inProgress, meta: ["codevisorExecution": "x"])
        .codevisorExecution == nil)
  }
}
