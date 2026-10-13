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

  @Test func completedCompactionLeavesNoWorkedSectionOrHistoryRow() {
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
    #expect(!ConversationItem.assistant(historical).hasRenderableTranscriptContent)
  }

  /// A live worked header says what the turn is doing, so it replaces the
  /// separate activity row from the first event until the turn ends.
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

    for projected in [thinking, running, settled, answering] {
      #expect(projected.first?.id == headerID)
      #expect(!projected.contains { $0.id == activityID })
    }
    // Reasoning before any work lands shows as the section's only line.
    #expect(
      thinking.map(\.id) == [headerID, .activeWorkedItem(messageID, .planning, itemID: WorkedItem.thinkingLineID)])
  }

  /// The opening line times the wait for the harness; once it answers, the
  /// header that takes over stays above the answer, live and settled, so
  /// nothing above it moves as the turn ends.
  @Test func answerOnlyTurnKeepsItsHeaderAboveTheAnswer() throws {
    var message = AssistantMessage(
      turn: AssistantTurn(isGenerating: true, startedAt: Date(timeIntervalSince1970: 100)))
    let header = TranscriptPresentationRow.ID.activeWorkedHeader(message.id, .planning)
    let opening = TranscriptActiveRowProjection.rows(for: .assistant(message))
    #expect(opening.map(\.id) == [.activeChrome(message.id, .activity)])

    message.turn.entries = [.text(id: "answer", markdown: "Hello.")]
    let answering = TranscriptActiveRowProjection.rows(for: .assistant(message))
    #expect(answering.first?.id == header)
    // The header takes the opening line's place with the same gap below it,
    // so the bottom-pinned transcript doesn't move when it does.
    #expect(answering.first?.spacingAfter == opening.first?.spacingAfter)
    #expect(!answering.contains { $0.id == .activeChrome(message.id, .activity) })

    message.turn.isGenerating = false
    message.turn.endedAt = Date(timeIntervalSince1970: 103)
    let settled = try TranscriptRowProjectionCache.project(
      makeInput(settled: [.assistant(message)]), options: .init(includesConnectingRow: true))
    #expect(settled.first?.id == .assistantWorkedHeader(message.id, .planning))
    #expect(message.turn.workedSectionTitle(.planning, now: .now) == "Worked for 3s")
  }

  @Test func streamedWorkedSectionKeepsAStableHeaderAsToolCallsArrive() {
    let messageID = UUID()
    let commentary = TranscriptEntry.text(id: "commentary", markdown: "Checking the code.")
    let initial = ConversationItem.assistant(
      AssistantMessage(
        id: messageID,
        turn: AssistantTurn(
          entries: [commentary],
          isGenerating: true,
          textPhases: ["commentary": .commentary]
        )
      )
    )
    let withTool = ConversationItem.assistant(
      AssistantMessage(
        id: messageID,
        turn: AssistantTurn(
          entries: [
            commentary,
            .tool(
              ToolCall(
                toolCallId: "read-1",
                title: "Read source",
                kind: .read,
                status: .inProgress
              )
            ),
          ],
          isGenerating: true,
          textPhases: ["commentary": .commentary]
        )
      )
    )

    let initialRows = TranscriptActiveRowProjection.rows(for: initial)
    let updatedRows = TranscriptActiveRowProjection.rows(for: withTool)
    let headerID = TranscriptPresentationRow.ID.activeWorkedHeader(
      messageID,
      .planning
    )

    #expect(initialRows.first?.id == headerID)
    #expect(updatedRows.first?.id == headerID)
    #expect(initialRows.first?.layoutKey == updatedRows.first?.layoutKey)
    #expect(
      updatedRows.contains {
        if case let .activeWorkedItem(reference) = $0.content {
          reference.itemID == "wgroup:read-1"
        } else {
          false
        }
      }
    )
  }

  @Test func deferredWorkedDetailsDoNotProjectALoadingContentRow() throws {
    let message = AssistantMessage(
      turn: AssistantTurn(
        entries: [.text(id: "answer", markdown: "Done")],
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
    // Nothing above the line ends the rail, nor puts space before it.
    #expect(reasoning.dropLast().allSatisfy { $0.spacingAfter == 0 })
    let note = try #require(
      reasoning.lazy.compactMap { if case let .markdownChunk(chunk) = $0.content { chunk } else { nil } }.first)
    #expect(note.timeline?.railBelow == true)

    // The next tool takes the line's place, as a group of its own rather
    // than joining the group above: same row count, nothing shifts.
    TranscriptToolReduction.applyCall(
      ToolCall(toolCallId: "sh", title: "Ran ls", kind: .execute, status: .inProgress, rawInput: ["command": "ls"]),
      to: &message.turn)
    #expect(!message.turn.isThinking)
    let running = worked()
    #expect(running.count == reasoning.count)
    #expect(!running.contains { $0.id == thinkingLine })
    #expect(Array(running.dropLast().map(\.id)) == Array(reasoning.dropLast().map(\.id)))

    // A gap the harness doesn't report as reasoning shows no line.
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
