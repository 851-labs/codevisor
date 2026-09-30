import ACPKit
import CodevisorCore
import Foundation
import Testing
import TranscriptKit
@testable import CodevisorUI

@MainActor
struct TranscriptWorkedRowsVisibilityTests {
  @Test("Worked content is removed before virtualization while its header remains")
  func collapsedRows() {
    let messageID = UUID()
    let message = AssistantMessage(
      id: messageID,
      turn: AssistantTurn(
        entries: [
          .text(id: "commentary", markdown: "One\n\nTwo\n\nThree")
        ],
        textPhases: ["commentary": .commentary]
      )
    )
    let rows = TranscriptActiveRowProjection.rows(for: .assistant(message))
    let store = TranscriptDisclosureStore()
    store.setExpanded(.turn(messageID), true)

    let initiallyExpanded = TranscriptWorkedRowsVisibility.present(
      rows,
      disclosure: store,
      activeItem: .assistant(message),
      runningSubagentRunToolCallIDs: []
    )
    #expect(initiallyExpanded.rows.contains(where: isWorkedContent))

    store.setExpanded(.turn(messageID), false)
    let collapsed = TranscriptWorkedRowsVisibility.present(
      rows,
      disclosure: store,
      activeItem: .assistant(message),
      runningSubagentRunToolCallIDs: []
    )

    #expect(collapsed.rows.contains { $0.id == .assistantWorkedHeader(messageID, .planning) })
    #expect(!collapsed.rows.contains(where: isWorkedContent))
    #expect(collapsed.visibilityRevision != initiallyExpanded.visibilityRevision)
  }

  @Test("Messaging a running agent keeps open only the turn that messaged it, not the one that spawned it")
  func runningSubagentOpensOnlyItsCurrentRun() {
    let spawn = ToolCall(toolCallId: "toolu_agent", title: "Agent: Slow haiku", kind: .agent, status: .completed)
    let followUp = ToolCall(
      toolCallId: "toolu_follow_up", title: "Messaged agent: Slow haiku", kind: .other, status: .completed)
    func finishedTurn(_ call: ToolCall, subagents: [String: SubagentTranscript] = [:]) -> AssistantMessage {
      AssistantMessage(
        turn: AssistantTurn(
          entries: [.tool(call), .text(id: "answer", markdown: "Done.")],
          stopReason: .endTurn,
          subagents: subagents,
          textPhases: ["answer": .final]))
    }
    let spawning = finishedTurn(
      spawn, subagents: ["toolu_agent": SubagentTranscript(entries: [.text(id: "t0", markdown: "A haiku.")])])
    let messaging = finishedTurn(followUp)
    func showsWork(_ message: AssistantMessage, whileRunning runIds: Set<String>) -> Bool {
      TranscriptWorkedRowsVisibility.present(
        TranscriptActiveRowProjection.rows(for: .assistant(message)),
        disclosure: TranscriptDisclosureStore(),
        activeItem: .assistant(message),
        runningSubagentRunToolCallIDs: runIds
      ).rows.contains(where: isWorkedContent)
    }

    #expect(showsWork(spawning, whileRunning: ["toolu_agent"]))
    #expect(!showsWork(spawning, whileRunning: ["toolu_follow_up"]))
    #expect(showsWork(messaging, whileRunning: ["toolu_follow_up"]))
    #expect(!showsWork(messaging, whileRunning: []))
  }

  private func isWorkedContent(_ row: TranscriptPresentationRow) -> Bool {
    row.workedSection?.role == .content
  }
}
