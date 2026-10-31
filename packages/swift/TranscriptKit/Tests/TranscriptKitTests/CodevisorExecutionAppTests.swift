import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

@Suite("Codevisor execution apps")
struct CodevisorExecutionAppTests {
  private static let zillow = #"""
    {"viewId":"v1","machineId":"cloud:dev-1","serverId":"mcp-z","serverName":"Zillow",
     "toolName":"search_homes","resourceUri":"ui://zillow/results.html"}
    """#

  private func execute(status: String, state: String, apps: String) throws -> ToolCall {
    let json = """
      {"toolCallId":"call","title":"mcp__codevisor__execute","status":"\(status)","isSnapshot":true,
       "rawInput":{"description":"Find homes"},
       "_meta":{"codevisorExecution":{"state":"\(state)","calls":[],"apps":\(apps)}}}
      """
    return try JSONDecoder().decode(ToolCall.self, from: Data(json.utf8))
  }

  @Test("A completed execute item exposes each app once, with its owning machine")
  func decodesApps() throws {
    let legacy = #"{"viewId":"v2","serverId":"mcp-g","resourceUri":"ui://g/a.html"}"#
    let broken = #"{"viewId":" ","serverId":"mcp-x","resourceUri":"ui://x"}"#
    let call = try execute(
      status: "completed", state: "completed", apps: "[\(Self.zillow),\(legacy),\(broken),\(Self.zillow)]")

    let apps = TranscriptPluginApps.apps(of: call)

    #expect(
      apps == [
        CodevisorExecutionApp(
          viewId: "v1", machineId: "cloud:dev-1", serverId: "mcp-z", serverName: "Zillow",
          toolName: "search_homes", resourceUri: "ui://zillow/results.html"),
        CodevisorExecutionApp(
          viewId: "v2", serverId: "mcp-g", serverName: "mcp-g", toolName: "", resourceUri: "ui://g/a.html"),
      ])
    #expect(apps[0].owningMachineId(fallback: "local") == "cloud:dev-1")
    #expect(apps[1].owningMachineId(fallback: "local") == "local")
  }

  @Test("Apps stay hidden until the execute item completes, and never show for a failed run")
  func onlyCompletedRuns() throws {
    let running = try execute(status: "in_progress", state: "running", apps: "[\(Self.zillow)]")
    let failed = try execute(status: "completed", state: "failed", apps: "[\(Self.zillow)]")
    let errored = try execute(status: "failed", state: "completed", apps: "[\(Self.zillow)]")

    #expect(TranscriptPluginApps.apps(of: running).isEmpty)
    #expect(TranscriptPluginApps.apps(of: failed).isEmpty)
    #expect(TranscriptPluginApps.apps(of: errored).isEmpty)
  }

  @Test("A worked section lists the apps of its tool calls in order without repeats")
  func workedSectionApps() throws {
    let other = #"{"viewId":"v2","serverId":"mcp-g","resourceUri":"ui://g/a.html"}"#
    let first = try execute(status: "completed", state: "completed", apps: "[\(Self.zillow)]")
    let again = try execute(status: "completed", state: "completed", apps: "[\(Self.zillow),\(other)]")
    let items: [WorkedItem] = [
      .text(id: "t", markdown: "Looking"),
      .toolGroup(ToolCallGroup(calls: [first])),
      .subagents(id: "a", calls: [first]),
      .toolGroup(ToolCallGroup(calls: [again])),
    ]

    #expect(TranscriptPluginApps.apps(in: items).map(\.viewId) == ["v1", "v2"])
  }

  @Test("A settled turn shows its apps from the item summary even before its tool calls load")
  func settledSummaryApps() throws {
    let summary = try JSONDecoder().decode(CodevisorExecutionApp.self, from: Data(Self.zillow.utf8))
    var turn = AssistantTurn(entries: [.text(id: "answer", markdown: "Here are homes.")], isGenerating: false)
    turn.pluginApps = [summary]
    let message = AssistantMessage(turn: turn)
    var rows: [TranscriptPresentationRow] = []

    TranscriptAssistantRowProjection.appendSettled(.assistant(message), waitingOnBackgroundTask: nil, to: &rows)

    let index = try #require(rows.firstIndex { $0.id == .assistantPluginApps(message.id) })
    #expect(rows[index].content == .pluginApps([summary]))
    #expect(
      rows.suffix(from: index + 1).contains { row in
        if case .markdownChunk = row.content { return true }
        return false
      })
  }
}
