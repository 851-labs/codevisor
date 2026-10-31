import ACPKit
import Foundation
import MarkdownCore
import Testing

@testable import TranscriptKit

struct TranscriptBubbleConversationTests {
  private let userID = UUID(uuidString: "6A1D2E8C-0000-4000-8000-000000000011")!
  private let replyID = UUID(uuidString: "6A1D2E8C-0000-4000-8000-000000000012")!
  private let queuedID = UUID(uuidString: "6A1D2E8C-0000-4000-8000-000000000013")!

  @Test func splitsTheReplyIntoBubblesAndLeavesTheAgentsWorkOut() throws {
    let reply = """
      First paragraph.

      ## Results
      Second paragraph after the heading.

      - one
      - two

        still item two

      ```swift
      let x = 1

      print(x)
      ```

      | a | b |
      |---|---|
      | 1 | 2 |

      ---

      > quoted
      """
    var turn = AssistantTurn(
      entries: [.text(id: "c1", markdown: "Let me check the repo."), .text(id: "f1", markdown: reply)])
    turn.textPhases = ["c1": .commentary, "f1": .final]

    let rows = try project(
      settled: [
        .user(UserMessage(id: userID, text: "summarize")), .assistant(AssistantMessage(id: replyID, turn: turn)),
      ],
      queued: [UserMessage(id: queuedID, text: "and then?")])

    #expect(
      rows.map(\.id)
        == [.message(userID)] + (0..<6).map { .botMessage(bubbleID($0)) } + [.message(queuedID), .bottomSpacer])
    #expect(
      bubbles(rows).map(\.message.text) == [
        "First paragraph.",
        "## Results\n\nSecond paragraph after the heading.",
        "- one\n- two\n\n  still item two",
        "```swift\nlet x = 1\n\nprint(x)\n```",
        "| a | b |\n|---|---|\n| 1 | 2 |",
        "> quoted",
      ])
    #expect(bubbles(rows)[4].content.blocks.first.map { if case .table = $0 { true } else { false } } == true)
    #expect(groupTails(rows) == (0..<6).map { $0 == 5 })
  }

  @Test func keepsAStreamingBubbleInPlaceAndShowsTypingOnlyWhileNoReplyIsShowing() throws {
    let working = try project(active: generating(entries: []))
    let streaming = try project(active: generating(entries: [.text(id: "f1", markdown: "One.\n\nTw")]))
    let streamed = try project(active: generating(entries: [.text(id: "f1", markdown: "One.\n\nTwo, done.")]))

    #expect(working.map(\.id) == [.botTyping, .bottomSpacer])
    #expect(streaming.map(\.id) == [.botMessage(bubbleID(0)), .botMessage(bubbleID(1)), .bottomSpacer])
    #expect(streamed.map(\.id) == streaming.map(\.id))
    #expect(bubbles(streamed).map(\.message.text) == ["One.", "Two, done."])
  }

  @Test func placesAnEarlierTurnsSetupRequestBeforeTheNextUserMessage() throws {
    let start = Date(timeIntervalSince1970: 1_792_324_800)
    let nextID = UUID(uuidString: "6A1D2E8C-0000-4000-8000-000000000014")!
    let laterReplyID = UUID(uuidString: "6A1D2E8C-0000-4000-8000-000000000015")!
    var first = AssistantTurn(
      entries: [.text(id: "f1", markdown: "Need screen access.")], startedAt: start, endedAt: start + 5)
    first.setupRequests = [TranscriptSetupRequest(id: "cu", kind: .computerUse, state: .pending)]
    let later = AssistantTurn(
      entries: [.text(id: "f2", markdown: "Thanks.")], startedAt: start + 60, endedAt: start + 65)

    let rows = try project(settled: [
      .user(UserMessage(id: userID, text: "look at Finder")),
      .assistant(AssistantMessage(id: replyID, turn: first)),
      .user(UserMessage(id: nextID, text: "granted")),
      .assistant(AssistantMessage(id: laterReplyID, turn: later)),
    ])

    #expect(
      rows.map(\.id) == [
        .botTimestamp(userID.uuidString.lowercased()), .message(userID), .botMessage(bubbleID(0)),
        .setupRequest("cu"), .message(nextID), .botMessage("\(laterReplyID.uuidString.lowercased()):0"),
        .bottomSpacer,
      ])
  }

  private func generating(entries: [TranscriptEntry]) -> ConversationItem {
    .assistant(AssistantMessage(id: replyID, turn: AssistantTurn(entries: entries, isGenerating: true)))
  }

  private func bubbleID(_ index: Int) -> String {
    "\(replyID.uuidString.lowercased()):\(index)"
  }

  private func bubbles(
    _ rows: [TranscriptPresentationRow]
  ) -> [(message: TranscriptBotMessage, content: TranscriptBotMessageContent)] {
    rows.compactMap { row in
      guard case let .botMessage(message, content, _) = row.content else { return nil }
      return (message, content)
    }
  }

  private func groupTails(_ rows: [TranscriptPresentationRow]) -> [Bool] {
    rows.compactMap { row in
      guard case let .botMessage(_, _, isGroupTail) = row.content else { return nil }
      return isGroupTail
    }
  }

  private func project(
    settled: [ConversationItem] = [], active: ConversationItem? = nil, queued: [UserMessage] = []
  ) throws -> [TranscriptPresentationRow] {
    try TranscriptRowProjectionCache.project(
      TranscriptProjectionInput(
        settledConversation: settled,
        pendingUserMessage: nil,
        activeItem: active,
        setupPhases: [],
        waitingBackgroundTaskDescription: nil,
        waitingHarnessUpdateName: nil,
        isLoadingInitialHistory: false,
        serverWaitMessage: nil,
        sessionErrorMessage: nil,
        status: .idle,
        outgoingMessages: queued
      ),
      options: .init(includesConnectingRow: false, bottomSpacerHeight: 80, presentsBubbleTranscript: true)
    )
  }
}
