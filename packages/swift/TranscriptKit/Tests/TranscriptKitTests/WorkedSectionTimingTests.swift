import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

/// A plan splits one turn into two worked sections that read like two
/// consecutive responses, each with its own "Worked for…" duration.
@Suite("Worked section timing around a plan")
struct WorkedSectionTimingTests {
  private let start = Date(timeIntervalSinceReferenceDate: 1_000)

  private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  private func planTurn(generating: Bool) -> AssistantTurn {
    var turn = AssistantTurn(
      entries: [.tool(ToolCall(toolCallId: "explore", title: "Read", kind: .read))],
      isGenerating: generating,
      planDocument: "1. Ship it",
      startedAt: start
    )
    turn.planBoundary = turn.entries.count
    turn.planProposedAt = at(42)
    return turn
  }

  @Test("No plan: one section timed over the whole turn")
  func noPlan() {
    var turn = AssistantTurn(isGenerating: true, startedAt: start)
    #expect(turn.workedSectionTitle(.planning, now: at(5)) == "Working for 5s")
    turn.isGenerating = false
    turn.endedAt = at(75)
    #expect(turn.workedSectionTitle(.planning, now: at(900)) == "Worked for 1m 15s")
  }

  @Test("The planning section settles once the plan lands, while the turn waits")
  func planningSettlesAtThePlan() {
    let turn = planTurn(generating: true)
    #expect(!turn.isWorkedSectionLive(.planning))
    #expect(!turn.workedSectionTicks(.planning))
    #expect(turn.workedSectionTitle(.planning, now: at(600)) == "Worked for 42s")
  }

  @Test("Work after approval is timed from the answer, excluding the wait")
  func implementationExcludesTheWait() {
    var turn = planTurn(generating: true)
    turn.planResumedAt = at(300)
    turn.entries.append(.tool(ToolCall(toolCallId: "build", title: "Edit", kind: .edit)))
    #expect(turn.isWorkedSectionLive(.implementation))
    #expect(turn.workedSectionTitle(.implementation, now: at(310)) == "Working for 10s")

    turn.isGenerating = false
    turn.endedAt = at(390)
    #expect(turn.workedSectionTitle(.planning, now: at(900)) == "Worked for 42s")
    #expect(turn.workedSectionTitle(.implementation, now: at(900)) == "Worked for 1m 30s")
  }

  @Test("A history snapshot times the plan before its details restore the boundary")
  func snapshotBeforeHydration() {
    var turn = planTurn(generating: false)
    turn.entries = []
    turn.planBoundary = nil
    turn.planResumedAt = at(60)
    turn.endedAt = at(90)
    #expect(turn.workedSectionTitle(.planning, now: at(900)) == "Worked for 42s")
  }

  @Test("History without plan times: a turn that ended at its plan keeps its duration")
  func legacyHistory() {
    var codex = planTurn(generating: false)
    codex.planProposedAt = nil
    codex.endedAt = at(50)
    #expect(codex.workedSectionTitle(.planning, now: at(900)) == "Worked for 50s")

    // Work followed the plan, so the turn's span cannot be attributed.
    var claude = codex
    claude.entries.append(.tool(ToolCall(toolCallId: "build", title: "Edit", kind: .edit)))
    #expect(claude.workedSectionTitle(.planning, now: at(900)) == "Worked")
  }
}
