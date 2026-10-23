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

  @Test func showsTheLatestTurnsSetupRequestAsItsOwnBubbleBeforeTyping() throws {
    var turn = AssistantTurn()
    turn.setupRequests = [TranscriptSetupRequest(id: "cu", kind: .computerUse, state: .pending)]
    let conversation = TranscriptBotConversation(
      messages: [message("b1", .bot, "Let me look at Finder.", at: 0)], isWorking: true)

    let rows = try TranscriptRowProjectionCache.project(
      input(settled: [.assistant(AssistantMessage(turn: turn))], conversation),
      options: .init(includesConnectingRow: false, presentsBotConversation: true)
    )

    #expect(rows.map(\.id) == [.botTimestamp("b1"), .botMessage("b1"), .setupRequest("cu"), .botTyping])
    #expect(rows[2].content == .setupRequest(turn.setupRequests[0], inBotConversation: true))
  }

  @Test func showsTheLatestTurnsStopInPlaceOfTheNoticeThatAnnouncedIt() throws {
    let stopped = AssistantMessage(
      turn: AssistantTurn(stopDetail: "You've hit your usage limit.", stopKind: "usageLimit"))
    let conversation = TranscriptBotConversation(
      messages: [
        message("n0", .notice, "You've hit your usage limit.", at: 0),
        message("b1", .bot, "On it.", at: 5),
        message("n1", .notice, "You've hit your usage limit.", at: 6),
      ],
      isWorking: false)

    let rows = try TranscriptRowProjectionCache.project(
      input(settled: [.assistant(stopped)], conversation, sessionError: "Couldn't cancel the resume."),
      options: .init(includesConnectingRow: false, presentsBotConversation: true)
    )

    #expect(
      rows.map(\.id) == [
        .botTimestamp("n0"), .botMessage("n0"), .botMessage("b1"), .assistantChrome(stopped.id, .epilogue), .error,
      ])
  }

  @Test func leavesAStopOutWhileTheLatestTurnIsStillWorking() throws {
    let working = AssistantMessage(
      turn: AssistantTurn(isGenerating: true, stopDetail: "You've hit your usage limit.", stopKind: "usageLimit"))
    let conversation = TranscriptBotConversation(
      messages: [message("n1", .notice, "You've hit your usage limit.", at: 0)], isWorking: true)

    let rows = try TranscriptRowProjectionCache.project(
      input(settled: [.assistant(working)], conversation),
      options: .init(includesConnectingRow: false, presentsBotConversation: true)
    )

    #expect(rows.map(\.id) == [.botTimestamp("n1"), .botMessage("n1"), .botTyping])
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

  @Test func marksUnconfirmedMessagesUnderTheirBubbles() throws {
    let failedID = UUID(uuidString: "6A1D2E8C-0000-4000-8000-000000000003")!
    let conversation = TranscriptBotConversation(
      messages: [
        message("b1", .bot, "Hi", at: 0),
        TranscriptBotMessage(id: userID.uuidString.lowercased(), sender: .user, text: "slow", delivery: .sending),
        TranscriptBotMessage(id: failedID.uuidString.lowercased(), sender: .user, text: "lost", delivery: .failed),
      ],
      isWorking: false
    )

    let rows = try TranscriptRowProjectionCache.project(
      input(conversation),
      options: .init(includesConnectingRow: false, presentsBotConversation: true)
    )

    #expect(
      rows.map(\.id) == [
        .botTimestamp("b1"),
        .botMessage("b1"),
        .message(userID),
        .delivery(userID),
        .message(failedID),
        .delivery(failedID),
      ])
    #expect(rows[3].content == .delivery(userID, .sending))
    #expect(rows[5].content == .delivery(failedID, .failed))
    #expect(rows.filter(\.isUserMessage).map(\.spacingAfter) == [2, 2])
  }

  @Test func marksUnconfirmedMessagesInANormalChat() throws {
    let steerID = UUID(uuidString: "6A1D2E8C-0000-4000-8000-000000000004")!
    let input = TranscriptProjectionInput(
      settledConversation: [.user(UserMessage(id: userID, text: "start"))],
      pendingUserMessage: UserMessage(id: steerID, text: "also this"),
      activeItem: nil,
      setupPhases: [],
      waitingBackgroundTaskDescription: nil,
      waitingHarnessUpdateName: nil,
      isLoadingInitialHistory: false,
      serverWaitMessage: nil,
      sessionErrorMessage: nil,
      status: .idle,
      outgoingMessages: [UserMessage(id: steerID, text: "also this")],
      deliveries: [userID: .sending, steerID: .failed]
    )

    let rows = try TranscriptRowProjectionCache.project(input, options: .init(includesConnectingRow: false))

    #expect(rows.map(\.id) == [.message(userID), .delivery(userID), .message(steerID), .delivery(steerID)])
    #expect(rows[1].content == .delivery(userID, .sending))
    #expect(rows[3].content == .delivery(steerID, .failed))
    #expect(rows.map(\.spacingAfter) == [2, nil, 2, nil])
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
      if case let .botMessage(message, _, isGroupTail) = row.content { tails[message.id] = isGroupTail }
    }
  }

  private func input(
    settled: [ConversationItem] = [],
    pending: UserMessage? = nil,
    _ conversation: TranscriptBotConversation,
    sessionError: String? = nil
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
      sessionErrorMessage: sessionError,
      status: .idle,
      botConversation: conversation
    )
  }
}
