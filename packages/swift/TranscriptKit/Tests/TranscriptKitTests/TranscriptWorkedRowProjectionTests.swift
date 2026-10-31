import Foundation
import Testing
import ACPKit
import CodevisorProtocol
@testable import TranscriptKit

struct TranscriptWorkedRowProjectionTests {
  @Test(arguments: [ContextCompactionStatus.started, .completed, .failed])
  func invisibleCompactionDoesNotAddSpaceBeforeActivity(status: ContextCompactionStatus) {
    var message = AssistantMessage(
      turn: AssistantTurn(
        entries: [
          .text(id: "commentary", markdown: "Checking the code."),
          .tool(ToolCall(toolCallId: "read", title: "Read source", status: .completed)),
        ],
        isGenerating: true,
        textPhases: ["commentary": .commentary]
      )
    )
    let waitingRows = TranscriptActiveRowProjection.rows(for: .assistant(message))
    message.turn.entries.append(.contextCompaction(id: "compact", status: status))
    let compactionRows = TranscriptActiveRowProjection.rows(for: .assistant(message))

    #expect(compactionRows.map(\.id) == waitingRows.map(\.id))
    #expect(compactionRows.map(\.estimatedHeight) == waitingRows.map(\.estimatedHeight))
    #expect(compactionRows.map(\.spacingAfter) == waitingRows.map(\.spacingAfter))
    #expect(compactionRows.first?.id == .activeWorkedHeader(message.id, .planning))
  }

  @Test func compactionBeforeAnyContentDoesNotCreateAnEmptyWorkedSection() {
    let message = AssistantMessage(
      turn: AssistantTurn(
        entries: [.contextCompaction(id: "compact", status: .started)],
        isGenerating: true
      )
    )
    let rows = TranscriptActiveRowProjection.rows(for: .assistant(message))

    #expect(rows.map(\.id) == [.activeChrome(message.id, .activity)])
  }

  @Test func compactionOnlyTurnShowsOnlyAMarkerOnceItEnds() {
    let message = AssistantMessage(
      turn: AssistantTurn(
        entries: [.contextCompaction(id: "compact", status: .completed)],
        isGenerating: true
      )
    )
    let rows = TranscriptActiveRowProjection.rows(for: .assistant(message))

    #expect(rows.map(\.id) == [.activeChrome(message.id, .activity)])
    var historical = message
    historical.turn.isGenerating = false
    #expect(historical.turn.workedItems.isEmpty)
    #expect(ConversationItem.assistant(historical).hasRenderableTranscriptContent)
    #expect(
      TranscriptActiveRowProjection.rows(for: .assistant(historical)).map(\.id) == [.compactionMarker(message.id)])
  }

  @Test func liveWorkedHeaderReplacesTheActivityRow() {
    let messageID = UUID()
    let commentary = TranscriptEntry.text(id: "commentary", markdown: "Checking the code.")
    func rows(_ entries: [TranscriptEntry]) -> [TranscriptPresentationRow] {
      TranscriptActiveRowProjection.rows(
        for: .assistant(
          AssistantMessage(
            id: messageID,
            turn: AssistantTurn(
              entries: entries,
              isGenerating: true,
              textPhases: ["commentary": .commentary]
            )
          )))
    }
    let activityID = TranscriptPresentationRow.ID.activeChrome(messageID, .activity)
    let headerID = TranscriptPresentationRow.ID.activeWorkedHeader(messageID, .planning)
    let thinking = TranscriptActiveRowProjection.rows(
      for: .assistant(
        AssistantMessage(
          id: messageID, turn: AssistantTurn(isGenerating: true, isThinking: true))))
    let running = rows([
      commentary,
      .tool(ToolCall(toolCallId: "read", title: "Read source", kind: .read, status: .inProgress)),
    ])
    let settled = rows([
      commentary,
      .tool(ToolCall(toolCallId: "read", title: "Read source", kind: .read, status: .completed)),
    ])
    let answering = rows([
      commentary,
      .tool(ToolCall(toolCallId: "read", title: "Read source", kind: .read, status: .completed)),
      .text(id: "answer", markdown: "The bug is in the parser."),
    ])

    for projected in [thinking, rows([commentary]), running, settled, answering] {
      #expect(projected.first?.id == headerID)
      #expect(!projected.contains { $0.id == activityID })
    }
    #expect(
      thinking.map(\.id) == [headerID, .activeWorkedItem(messageID, .planning, itemID: WorkedItem.thinkingLineID)])
  }

  @Test func answerOnlyTurnKeepsItsHeaderAboveTheAnswer() throws {
    var message = AssistantMessage(
      turn: AssistantTurn(isGenerating: true, startedAt: Date(timeIntervalSince1970: 100)))
    let header = TranscriptPresentationRow.ID.activeWorkedHeader(message.id, .planning)
    let opening = TranscriptActiveRowProjection.rows(for: .assistant(message))
    #expect(opening.map(\.id) == [.activeChrome(message.id, .activity)])

    message.turn.entries = [.text(id: "answer", markdown: "Hello.")]
    let answering = TranscriptActiveRowProjection.rows(for: .assistant(message))
    #expect(answering.first?.id == header)
    #expect(answering.first?.spacingAfter == opening.first?.spacingAfter)
    #expect(!answering.contains { $0.id == .activeChrome(message.id, .activity) })

    message.turn.isGenerating = false
    message.turn.endedAt = Date(timeIntervalSince1970: 103)
    let settled = try TranscriptRowProjectionCache.project(
      makeInput(settled: [.assistant(message)]), options: .init(includesConnectingRow: true))
    #expect(settled.first?.id == .assistantWorkedHeader(message.id, .planning))
    #expect(message.turn.workedSectionTitle(.planning, now: .now) == "Worked for 3s")
  }

  @Test func deferredWorkedDetailsDoNotProjectALoadingContentRow() throws {
    let message = AssistantMessage(
      turn: AssistantTurn(
        entries: [.text(id: "note", markdown: "Checking the code."), .text(id: "answer", markdown: "Done")],
        textPhases: ["note": .commentary],
        deferredDetailItemId: "detail-1",
        hasDeferredWorkedDetails: true,
        detailRevision: 1
      )
    )

    let rows = try TranscriptRowProjectionCache.project(
      makeInput(settled: [.assistant(message)]),
      options: .init(includesConnectingRow: true)
    )
    let workedRows = rows.filter {
      $0.workedSection?.identity
        == TranscriptWorkedSectionIdentity(messageID: message.id, kind: .planning)
    }

    #expect(workedRows.count == 1)
    guard let role = workedRows.first?.workedSection?.role,
      case .header = role
    else {
      Issue.record("expected only the worked-section header")
      return
    }
  }

  @Test func thousandLineWorkedSectionRemainsBlockVirtualized() throws {
    let messageID = UUID()
    let markdown = (1...1_000)
      .map { "Paragraph \($0)" }
      .joined(separator: "\n\n")
    let active = ConversationItem.assistant(
      AssistantMessage(
        id: messageID,
        turn: AssistantTurn(
          entries: [.text(id: "commentary", markdown: markdown)],
          isGenerating: true,
          textPhases: ["commentary": .commentary]
        )
      )
    )
    let settled = ConversationItem.assistant(
      AssistantMessage(
        id: messageID,
        turn: AssistantTurn(
          entries: [.text(id: "commentary", markdown: markdown)],
          textPhases: ["commentary": .commentary]
        )
      )
    )

    let activeRows = TranscriptActiveRowProjection.rows(for: active)
    let settledRows = try TranscriptRowProjectionCache.project(
      makeInput(settled: [settled]),
      options: .init(includesConnectingRow: true)
    )
    let activeWorkedRows = activeRows.filter { $0.workedSection != nil }
    let settledWorkedRows = settledRows.filter { $0.workedSection != nil }

    #expect(activeWorkedRows.count > 100)
    #expect(activeWorkedRows.first?.id == .activeWorkedHeader(messageID, .planning))
    #expect(settledWorkedRows.first?.id == .assistantWorkedHeader(messageID, .planning))
    #expect(activeWorkedRows.map(\.layoutKey) == settledWorkedRows.map(\.layoutKey))
    #expect(
      activeWorkedRows.dropFirst().allSatisfy {
        $0.workedSection?.role == .content
      }
    )
  }

  @Test("Thinking ends a live section only while the harness reports reasoning, and what follows takes its place")
  func thinkingLineFollowsReasoning() throws {
    var message = AssistantMessage(
      turn: AssistantTurn(
        entries: [
          .text(id: "note", markdown: "Checking the code."),
          .tool(ToolCall(toolCallId: "read", title: "Read source", kind: .read, status: .completed)),
        ],
        isGenerating: true,
        isThinking: true,
        textPhases: ["note": .commentary]
      )
    )
    func worked() -> [TranscriptPresentationRow] {
      TranscriptActiveRowProjection.rows(for: .assistant(message)).filter { $0.workedSection?.role == .content }
    }
    let thinkingLine = TranscriptPresentationRow.ID.activeWorkedItem(
      message.id, .planning, itemID: WorkedItem.thinkingLineID)
    let reasoning = worked()
    #expect(reasoning.last?.id == thinkingLine)
    #expect(reasoning.dropLast().allSatisfy { $0.spacingAfter == 0 })
    let note = try #require(
      reasoning.lazy.compactMap { if case let .markdownChunk(chunk) = $0.content { chunk } else { nil } }.first)
    #expect(note.timeline?.railBelow == true)

    TranscriptToolReduction.applyCall(
      ToolCall(toolCallId: "sh", title: "Ran ls", kind: .execute, status: .inProgress, rawInput: ["command": "ls"]),
      to: &message.turn)
    #expect(!message.turn.isThinking)
    let running = worked()
    #expect(running.count == reasoning.count)
    #expect(!running.contains { $0.id == thinkingLine })
    #expect(Array(running.dropLast().map(\.id)) == Array(reasoning.dropLast().map(\.id)))

    message.turn.entries[2] = .tool(
      ToolCall(toolCallId: "sh", title: "Ran ls", kind: .execute, status: .completed, rawInput: ["command": "ls"]))
    #expect(!worked().contains { $0.id == thinkingLine })
  }

  private func makeInput(
    settled: [ConversationItem]
  ) -> TranscriptProjectionInput {
    TranscriptProjectionInput(
      settledConversation: settled,
      pendingUserMessage: nil,
      activeItem: nil,
      setupPhases: [],
      waitingBackgroundTaskDescription: nil,
      waitingHarnessUpdateName: nil,
      isLoadingInitialHistory: false,
      serverWaitMessage: nil,
      sessionErrorMessage: nil,
      status: .idle
    )
  }
}

@Suite("Awaited agents")
struct AwaitedAgentTests {
  private func agent(_ id: String, _ status: ToolCallStatus, background: Bool = false) -> TranscriptEntry {
    .tool(
      ToolCall(
        toolCallId: id, title: "Agent: \(id)", kind: .agent, status: status,
        rawInput: ["description": .string(id), "run_in_background": .bool(background)]))
  }

  @Test("A live turn waits on the open agents its work ends with, and on nothing else")
  func awaitedAgents() {
    var turn = AssistantTurn(
      entries: [.text(id: "note", markdown: "Checking."), agent("map", .inProgress), agent("audit", .inProgress)],
      isGenerating: true)
    #expect(turn.awaitedAgentCalls.map(\.toolCallId) == ["map", "audit"])

    turn.entries = [agent("map", .completed, background: true)]
    #expect(turn.awaitedAgentCalls.isEmpty)

    turn.entries = [
      agent("map", .inProgress),
      .tool(ToolCall(toolCallId: "ls", title: "Ran ls", kind: .execute, status: .inProgress)),
    ]
    #expect(turn.awaitedAgentCalls.isEmpty)

    turn.entries = [agent("map", .inProgress)]
    turn.isGenerating = false
    #expect(turn.awaitedAgentCalls.isEmpty)
  }
}
