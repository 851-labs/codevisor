import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptWorkedRowStabilityTests {
  private let messageID = UUID()

  @Test("A streamed update changes only the worked lines it touches")
  func updateChangesOnlyTheLinesItTouches() {
    let running = workedLineRows([tool("a", .completed), note("n1"), tool("b", .inProgress)])
    let finished = workedLineRows([tool("a", .completed), note("n1"), tool("b", .completed)])
    let extended = workedLineRows([
      tool("a", .completed), note("n1"), tool("b", .completed), note("n2"), tool("c", .inProgress),
    ])

    #expect(changedLines(from: running, to: finished) == ["wgroup:b"])
    #expect(changedLines(from: finished, to: extended) == ["wgroup:b"])
    #expect(line("wgroup:b", in: finished)?.isLast == true)
    #expect(line("wgroup:b", in: extended)?.isLast == false)
    #expect(line("wgroup:c", in: extended)?.isLast == true)
  }

  @Test("Only the agents line carries the agents the turn is waiting on")
  func awaitedAgentsStayOnTheirLine() {
    let agent = ToolCall(
      toolCallId: "research", title: "Agent: Research", kind: .agent, status: .inProgress,
      rawInput: ["description": "Research"])
    let rows = workedLineRows([tool("a", .completed), note("n1"), .tool(agent)])

    #expect(line("wagent:research", in: rows)?.awaitedAgents.map(\.toolCallId) == ["research"])
    #expect(line("wgroup:a", in: rows)?.awaitedAgents.isEmpty == true)
  }

  @Test("Streamed text leaves the working header unchanged")
  func streamedTextLeavesTheHeaderUnchanged() throws {
    let started = try #require(header([tool("a", .completed), .text(id: "n1", markdown: "Checking")]))
    let grown = try #require(header([tool("a", .completed), .text(id: "n1", markdown: "Checking the parser")]))
    let nextStep = try #require(
      header([tool("a", .completed), .text(id: "n1", markdown: "Checking the parser"), tool("b", .inProgress)]))

    #expect(grown == started)
    #expect(nextStep != grown)
  }

  private func header(_ entries: [TranscriptEntry]) -> TranscriptPresentationRow? {
    activeRows(entries).first { row in
      if case .workedHeader = row.content { true } else { false }
    }
  }

  private func activeRows(_ entries: [TranscriptEntry]) -> [TranscriptPresentationRow] {
    let turn = AssistantTurn(
      entries: entries,
      isGenerating: true,
      startedAt: Date(timeIntervalSince1970: 100),
      textPhases: ["n1": .commentary, "n2": .commentary]
    )
    return TranscriptActiveRowProjection.rows(for: .assistant(AssistantMessage(id: messageID, turn: turn)))
  }

  private func workedLineRows(_ entries: [TranscriptEntry]) -> [String: TranscriptPresentationRow] {
    Dictionary(
      uniqueKeysWithValues: activeRows(entries).compactMap { row in
        guard case let .workedLine(line) = row.content else { return nil }
        return (line.reference.itemID, row)
      })
  }

  private func changedLines(
    from previous: [String: TranscriptPresentationRow],
    to current: [String: TranscriptPresentationRow]
  ) -> [String] {
    previous.keys.filter { current[$0] != nil && current[$0] != previous[$0] }.sorted()
  }

  private func line(_ itemID: String, in rows: [String: TranscriptPresentationRow]) -> TranscriptWorkedLine? {
    guard case let .workedLine(line)? = rows[itemID]?.content else { return nil }
    return line
  }

  private func tool(_ id: String, _ status: ToolCallStatus) -> TranscriptEntry {
    .tool(ToolCall(toolCallId: id, title: "Run \(id)", kind: .execute, status: status, rawInput: ["command": "ls"]))
  }

  private func note(_ id: String) -> TranscriptEntry {
    .text(id: id, markdown: "Checking \(id).")
  }
}
