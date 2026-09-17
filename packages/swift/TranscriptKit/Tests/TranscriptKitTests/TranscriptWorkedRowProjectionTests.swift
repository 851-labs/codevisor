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
    #expect(compactionRows.last?.id == .activeChrome(message.id, .activity))
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
    #expect(!message.turn.hasWorkedContent)
    var historical = message
    historical.turn.isGenerating = false
    #expect(historical.turn.workedItems.isEmpty)
    #expect(!ConversationItem.assistant(historical).hasRenderableTranscriptContent)
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
