import ACPKit
import CodevisorProtocol
import Foundation
import Testing

@testable import TranscriptKit

struct TranscriptBotRowAssemblyTests {
  private let start = Date(timeIntervalSince1970: 1_792_324_800)
  private let userID = UUID(uuidString: "6A1D2E8C-0000-4000-8000-000000000001")!
  private let pendingID = UUID(uuidString: "6A1D2E8C-0000-4000-8000-000000000002")!

  @Test func presentsTheFeedAsBubblesInsteadOfTheAgentTranscript() throws {
    let turn = AssistantMessage(turn: AssistantTurn(entries: [.text(id: "work", markdown: "Thinking out loud")]))
    let conversation = TranscriptBotConversation(
      messages: [
        message(userID.uuidString.lowercased(), .user, "what's in the repo?", at: 0),
        message("b1", .bot, "A tiny CLI.", at: 5),
        message("b2", .bot, "Want an agent on it?", at: 6),
        message("n1", .notice, "Couldn't reply: rate limited", at: 20 * 60),
      ],
      isWorking: true
    )

    let rows = try TranscriptRowProjectionCache.project(
      input(settled: [.assistant(turn)], pending: UserMessage(id: pendingID, text: "yes"), conversation),
      options: .init(includesConnectingRow: false, bottomSpacerHeight: 80, presentsBotConversation: true)
    )

    #expect(
      rows.map(\.id) == [
        .botTimestamp(userID.uuidString.lowercased()),
        .message(userID),
        .botMessage("b1"),
        .botMessage("b2"),
        .botTimestamp("n1"),
        .botMessage("n1"),
        .message(pendingID),
        .botTyping,
        .bottomSpacer,
      ])
    #expect(groupTails(rows) == ["b1": false, "b2": true, "n1": true])
    #expect(!rows.contains { $0.id.isActiveRow || $0.id == .startingAgent })
  }

  @Test func dropsThePendingRowOnceTheServerEchoesTheSend() throws {
    let echoed = message(pendingID.uuidString.lowercased(), .user, "yes", at: 0)

    let rows = try TranscriptRowProjectionCache.project(
      input(
        pending: UserMessage(id: pendingID, text: "yes"),
        TranscriptBotConversation(messages: [echoed], isWorking: false)),
      options: .init(includesConnectingRow: false, presentsBotConversation: true)
    )

    #expect(rows.map(\.id) == [.botTimestamp(echoed.id), .message(pendingID)])
    #expect(rows.last?.isUserMessage == true)
  }

  @Test func keepsTheAgentTranscriptForTheFullTranscriptView() throws {
    let rows = try TranscriptRowProjectionCache.project(
      input(
        settled: [.user(UserMessage(id: userID, text: "hi"))],
        TranscriptBotConversation(messages: [message("b1", .bot, "hello", at: 0)], isWorking: false)
      ),
      options: .init(includesConnectingRow: false)
    )

    #expect(rows.map(\.id) == [.message(userID)])
  }

  private func message(
    _ id: String, _ sender: TranscriptBotMessage.Sender, _ text: String, at seconds: TimeInterval
  ) -> TranscriptBotMessage {
    TranscriptBotMessage(id: id, sender: sender, text: text, sentAt: start.addingTimeInterval(seconds))
  }

  private func groupTails(_ rows: [TranscriptPresentationRow]) -> [String: Bool] {
    rows.reduce(into: [:]) { tails, row in
      if case let .botMessage(message, isGroupTail) = row.content { tails[message.id] = isGroupTail }
    }
  }

  private func input(
    settled: [ConversationItem] = [],
    pending: UserMessage? = nil,
    _ conversation: TranscriptBotConversation
  ) -> TranscriptProjectionInput {
    TranscriptProjectionInput(
      settledConversation: settled,
      pendingUserMessage: pending,
      activeItem: nil,
      setupPhases: [],
      waitingBackgroundTaskDescription: nil,
      waitingHarnessUpdateName: nil,
      isLoadingInitialHistory: false,
      serverWaitMessage: nil,
      sessionErrorMessage: nil,
      status: .idle,
      botConversation: conversation
    )
  }
}
