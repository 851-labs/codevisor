import ACPKit
import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

@Suite("Live worked header label")
struct WorkedSectionActivityTests {
  @Test("Before the harness's first event the turn times the wait from its start, with no label")
  func waitingOnTheHarness() {
    let start = Date(timeIntervalSince1970: 100)
    var turn = AssistantTurn(isGenerating: true, startedAt: start)
    #expect(turn.harnessWaitStartedAt == start)
    #expect(turn.workedSectionActivity == .starting)

    turn.isThinking = true
    #expect(turn.harnessWaitStartedAt == nil)
    #expect(turn.workedSectionActivity == .step("Thinking"))
  }

  @Test("A turn blocked on its agents names them, and its agent line says what became of them")
  func agentWording() {
    func agent(_ id: String, _ status: ToolCallStatus, background: Bool = false) -> ToolCall {
      ToolCall(
        toolCallId: id, title: "Agent: \(id)", kind: .agent, status: status,
        rawInput: ["description": .string(id), "run_in_background": .bool(background)])
    }
    let map = agent("Map the UI", .inProgress)
    let audit = agent("Audit tests", .inProgress)
    var turn = AssistantTurn(entries: [.tool(map), .tool(audit)], isGenerating: true)
    #expect(turn.workedSectionActivity == .step("Waiting for Map the UI and Audit tests"))
    #expect(
      WorkedTimelineText.title(calls: [], agents: [map, audit], awaited: turn.awaitedAgentCalls)
        == "Waiting for Map the UI and Audit tests")
    #expect(
      WorkedTimelineText.waiting(for: [map, audit, agent("Third", .inProgress)]) == "Waiting for 3 agents")

    let ran = agent("Map the UI", .completed)
    let launched = agent("Map the UI", .completed, background: true)
    #expect(WorkedTimelineText.title(calls: [], agents: [ran], awaited: []) == "Ran an agent")
    #expect(WorkedTimelineText.title(calls: [], agents: [launched, launched], awaited: []) == "Started 2 agents")
    turn.entries.append(.tool(ToolCall(toolCallId: "ls", title: "Ran ls", kind: .execute, status: .inProgress)))
    #expect(WorkedTimelineText.title(calls: [], agents: [map], awaited: turn.awaitedAgentCalls) == "Started an agent")
  }

  @Test("The label names the current step without a trailing ellipsis")
  func labels() {
    var turn = AssistantTurn(isGenerating: true, isThinking: true)
    #expect(turn.workedSectionActivity == .step("Thinking"))

    turn.isThinking = false
    turn.entries = [.tool(ToolCall(toolCallId: "edit", title: "Edit", kind: .edit, status: .inProgress))]
    #expect(turn.workedSectionActivity == .step("Editing file"))

    turn.entries = [.tool(ToolCall(toolCallId: "ls", title: "Ran ls", kind: .execute, status: .completed))]
    #expect(turn.workedSectionActivity == .step("Thinking"))

    turn.entries.append(.text(id: "answer", markdown: "Done."))
    #expect(turn.workedSectionActivity == .answering)
  }

  @Test("A tool announced by its bare name waits for its real title")
  func pendingTitles() {
    var turn = AssistantTurn(
      entries: [.tool(ToolCall(toolCallId: "sh", title: "Bash", kind: .execute, status: .inProgress))],
      isGenerating: true)
    #expect(turn.workedSectionActivity == .pending)
    turn.entries = [
      .tool(
        ToolCall(
          toolCallId: "sh", title: "Bash", kind: .execute, status: .inProgress, rawInput: ["command": "ls"]))
    ]
    #expect(turn.workedSectionActivity == .step("Bash"))
    turn.entries = [.tool(ToolCall(toolCallId: "sh", title: "Ran sleep 6", kind: .execute, status: .inProgress))]
    #expect(turn.workedSectionActivity == .step("Ran sleep 6"))
  }
}

@Suite("Live worked header pacing")
struct WorkedActivityLabelSmootherTests {
  private let start = Date(timeIntervalSinceReferenceDate: 1_000)
  private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  @Test("The first subject shows at once, a tool still writing its input as thinking")
  func firstSubject() {
    var smoother = WorkedActivityLabelSmoother()
    smoother.observe(.pending, now: at(0))
    #expect(smoother.shown == .step("Thinking"))
    #expect(smoother.deadline == nil)
  }

  @Test("A new subject shows once it has held, so a preamble retagged at once never flashes")
  func settles() {
    var smoother = WorkedActivityLabelSmoother()
    smoother.observe(.step("Thinking"), now: at(0))
    smoother.observe(.answering, now: at(5))
    #expect(smoother.shown == .step("Thinking"))
    #expect(smoother.deadline == at(5.3))
    smoother.observe(.pending, now: at(5.05))
    smoother.observe(.step("Ran sleep 6"), now: at(5.1))
    smoother.tick(now: at(5.3))
    #expect(smoother.shown == .step("Thinking"))
    let deadline = smoother.deadline
    #expect(deadline == at(5.1).addingTimeInterval(WorkedActivityLabelSmoother.settleInterval))
    smoother.tick(now: deadline!)
    #expect(smoother.shown == .step("Ran sleep 6"))
    #expect(smoother.deadline == nil)
  }

  @Test("A burst of quick steps skips most of them but keeps the header moving")
  func bursts() {
    var smoother = WorkedActivityLabelSmoother()
    smoother.observe(.step("Read a"), now: at(0))
    var shownAt: [Int: WorkedSectionActivity?] = [:]
    for index in 1...15 {
      smoother.observe(.step("Read \(index)"), now: at(Double(index) / 8))
      shownAt[index] = smoother.shown
    }
    #expect(shownAt[10] == .step("Read a"))
    #expect(shownAt[11] == .step("Read 11"))
    #expect(shownAt[15] == .step("Read 11"))
    smoother.observe(.step("Read 11"), now: at(2))
    #expect(smoother.deadline == nil)
  }

  @Test("A pending step never replaces the label, nor starts it going out of date")
  func pending() {
    var smoother = WorkedActivityLabelSmoother()
    smoother.observe(.step("Thinking"), now: at(0))
    smoother.observe(.pending, now: at(1))
    #expect(smoother.deadline == nil)
    smoother.tick(now: at(9))
    #expect(smoother.shown == .step("Thinking"))
  }
}
