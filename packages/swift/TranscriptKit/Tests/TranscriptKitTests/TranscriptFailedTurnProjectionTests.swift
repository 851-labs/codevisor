import Foundation
import Testing
import ACPKit
import CodevisorProtocol
@testable import TranscriptKit

struct TranscriptFailedTurnProjectionTests {
  @Test func failedActiveTurnWithWorkedItemsProjectsItsStopDetailRow() throws {
    let messageID = UUID()
    let failed = ConversationItem.assistant(
      AssistantMessage(
        id: messageID,
        turn: AssistantTurn(
          entries: [
            .tool(
              ToolCall(
                toolCallId: "read-1",
                title: "Read source",
                kind: .read,
                status: .completed
              )
            )
          ],
          isGenerating: false,
          stopDetail: "codex: 401 Unauthorized"
        )
      )
    )

    let activeRows = TranscriptActiveRowProjection.rows(for: failed)
    var settledRows: [TranscriptPresentationRow] = []
    TranscriptAssistantRowProjection.appendSettled(
      failed,
      waitingOnBackgroundTask: nil,
      to: &settledRows
    )
    let epilogue = try #require(activeRows.last)

    #expect(epilogue.id == .assistantChrome(messageID, .epilogue))
    #expect(activeRows.map(\.layoutKey) == settledRows.map(\.layoutKey))
    #expect(activeRows.filter { $0.id == .assistantChrome(messageID, .epilogue) }.count == 1)
  }

  @Test func failedActiveTurnWithoutContentProjectsAPreciseStopDetailRow() throws {
    let messageID = UUID()
    let failed = ConversationItem.assistant(
      AssistantMessage(
        id: messageID,
        turn: AssistantTurn(isGenerating: false, stopDetail: "codex: 401 Unauthorized")
      )
    )

    let rows = TranscriptActiveRowProjection.rows(for: failed)
    var settledRows: [TranscriptPresentationRow] = []
    TranscriptAssistantRowProjection.appendSettled(
      failed,
      waitingOnBackgroundTask: nil,
      to: &settledRows
    )

    #expect(rows.map(\.id) == [.assistantChrome(messageID, .epilogue)])
    #expect(settledRows.map(\.id) == [.assistantChrome(messageID, .epilogue)])
    #expect(settledRows.map(\.layoutKey) == rows.map(\.layoutKey))
  }

  @Test func olderFailedTurnsProjectNoStopDetail() throws {
    let olderErrorOnly = AssistantMessage(
      turn: AssistantTurn(stopDetail: "codex: 401 Unauthorized")
    )
    let olderWithWork = AssistantMessage(
      turn: AssistantTurn(
        entries: [
          .tool(
            ToolCall(
              toolCallId: "read-1", title: "Read source", kind: .read, status: .completed
            ))
        ],
        stopDetail: "codex: 503 Overloaded"
      )
    )
    let latest = AssistantMessage(turn: AssistantTurn(stopDetail: "codex: 429 Rate limited"))
    let user = ConversationItem.user(UserMessage(text: "again"))

    let rows = try TranscriptRowProjectionCache.project(
      makeInput(settled: [
        .assistant(olderErrorOnly), user, .assistant(olderWithWork), user, .assistant(latest),
      ]),
      options: .init(includesConnectingRow: true)
    )
    let epilogues = rows.filter {
      if case .assistantChrome(_, .epilogue) = $0.id { true } else { false }
    }

    #expect(!rows.contains { $0.id.messageID == olderErrorOnly.id })
    #expect(rows.contains { $0.id.messageID == olderWithWork.id })
    #expect(epilogues.map { $0.id.messageID } == [latest.id])
    #expect(
      !rows.contains { row in
        if case let .assistantChrome(message, _, _) = row.content {
          message.id != latest.id && message.turn.stopDetail != nil
        } else {
          false
        }
      })

    let withActive = try TranscriptRowProjectionCache.project(
      makeInput(
        settled: [.assistant(latest), user],
        active: .assistant(AssistantMessage(turn: AssistantTurn(isGenerating: true)))
      ),
      options: .init(includesConnectingRow: true)
    )
    #expect(!withActive.contains { $0.id.messageID == latest.id })
  }

  @Test func stopDetailNeverProjectsWhileTheTurnIsStillGenerating() {
    let generating = ConversationItem.assistant(
      AssistantMessage(
        turn: AssistantTurn(isGenerating: true, stopDetail: "stale detail")
      )
    )
    let answered = ConversationItem.assistant(
      AssistantMessage(
        turn: AssistantTurn(
          entries: [.text(id: "answer", markdown: "Done")],
          isGenerating: false,
          stopDetail: "Truncated"
        )
      )
    )

    let generatingRows = TranscriptActiveRowProjection.rows(for: generating)
    let answeredRows = TranscriptActiveRowProjection.rows(for: answered)

    #expect(generatingRows.map(\.id) == [.activeChrome(generating.id, .activity)])
    #expect(answeredRows.filter { $0.id == .assistantChrome(answered.id, .epilogue) }.count == 1)
  }

  private func makeInput(
    settled: [ConversationItem] = [],
    pending: UserMessage? = nil,
    active: ConversationItem? = nil,
    setup: [SessionSetupPhase] = [],
    isLoadingInitialHistory: Bool = false,
    sessionError: String? = nil,
    status: TranscriptProjectionInput.ConnectionStatus = .idle
  ) -> TranscriptProjectionInput {
    TranscriptProjectionInput(
      settledConversation: settled,
      pendingUserMessage: pending,
      activeItem: active,
      setupPhases: setup,
      waitingBackgroundTaskDescription: nil,
      waitingHarnessUpdateName: nil,
      isLoadingInitialHistory: isLoadingInitialHistory,
      serverWaitMessage: nil,
      sessionErrorMessage: sessionError,
      status: status
    )
  }
}
