import ACPKit
import CodevisorProtocol
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptCompactionProjectionTests {
  @Test("A /compact turn shows a marker, and the conversation after it keeps its own rows")
  func compactTurnKeepsLaterTurns() throws {
    let compact = UserMessage(text: "/compact")
    let compacted = AssistantMessage(
      turn: AssistantTurn(entries: [.contextCompaction(id: "c", status: .completed)]))
    let question = UserMessage(text: "What word did you reply with?")
    let answer = AssistantMessage(turn: AssistantTurn(entries: [.text(id: "a", markdown: "hello")]))

    let rows = try project([.user(compact), .assistant(compacted), .user(question), .assistant(answer)])

    #expect(
      rows.map(\.id) == [
        .message(compact.id),
        .compactionMarker(compacted.id),
        .message(question.id),
        .assistantWorkedHeader(answer.id, .planning),
        .assistantMarkdown(answer.id, sourceID: "a:0", ordinal: 0, fragment: nil),
        .assistantChrome(answer.id, .epilogue),
      ])
  }

  @Test("A compaction inside a working turn adds no marker")
  func compactionInsideAWorkingTurnAddsNoMarker() throws {
    let answer = AssistantMessage(
      turn: AssistantTurn(entries: [
        .contextCompaction(id: "c", status: .completed), .text(id: "a", markdown: "Done."),
      ]))

    let rows = try project([.assistant(answer)])

    #expect(!rows.contains { $0.id == .compactionMarker(answer.id) })
  }

  private func project(_ settled: [ConversationItem]) throws -> [TranscriptPresentationRow] {
    try TranscriptRowProjectionCache.project(
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
      ),
      options: .init(includesConnectingRow: false)
    ).filter { $0.id != .bottomSpacer }
  }
}
