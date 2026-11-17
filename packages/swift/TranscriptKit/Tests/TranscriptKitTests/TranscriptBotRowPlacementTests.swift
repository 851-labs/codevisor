import ACPKit
import Foundation
import Testing

@testable import TranscriptKit

struct TranscriptBotRowPlacementTests {
  private let start = Date(timeIntervalSince1970: 1_792_324_800)
  private let sentID = UUID(uuidString: "6A1D2E8C-0000-4000-8000-0000000000A1")!
  private let options = TranscriptProjectionOptions(includesConnectingRow: false, presentsBotConversation: true)

  @Test func aSendKeepsItsRowWhereTheServerEchoPutsIt() throws {
    let scout = event(from: "scout", at: 10)
    let builder = event(from: "builder", at: 20)
    let settled: [ConversationItem] = [
      .user(scout), .assistant(AssistantMessage(turn: askingTurn(endedAt: 15))),
      .user(builder), .assistant(AssistantMessage(turn: AssistantTurn(startedAt: at(20), endedAt: at(21)))),
    ]
    let earlier = [message("b1", .bot, "I asked the team.", at: 5)]
    let sent = TranscriptBotMessage(id: sentID.uuidString.lowercased(), sender: .user, text: "Next?")

    let typed = try rows(settled, earlier, pending: UserMessage(id: sentID, text: "Next?"))
    let sending = try rows(settled, earlier + [sent])
    let echoed = try rows(settled, earlier + [message(sent.id, .user, "Next?", at: 30)])

    #expect(typed == echoed)
    #expect(sending == echoed)
    #expect(
      echoed == [
        .botTimestamp("b1"), .botMessage("b1"), .eventMarker(scout.id), .setupRequest("cu"), .interaction("q"),
        .eventMarker(builder.id), .message(sentID),
      ])
  }

  @Test func aSendAfterAQuietSpellShowsItsTimeBeforeTheServerEchoesIt() throws {
    let earlier = [message("b1", .bot, "Done for today.", at: 0)]
    let id = sentID.uuidString.lowercased()
    let sending = TranscriptBotMessage(id: id, sender: .user, text: "Morning", localSentAt: at(20 * 60))

    let pending = try rows([], earlier + [sending])
    let echoed = try rows([], earlier + [message(id, .user, "Morning", at: 20 * 60 + 1)])

    #expect(pending == echoed)
    #expect(echoed == [.botTimestamp("b1"), .botMessage("b1"), .botTimestamp(id), .message(sentID)])
  }

  @Test func anEventTheBotReadLateStaysAboveAMessageSentAfterIt() throws {
    let scout = event(from: "scout", at: 10)
    let longJob = AssistantTurn(startedAt: at(5), endedAt: at(40))
    let scoutReply = AssistantTurn(startedAt: at(40.5), endedAt: at(41))
    let conversation = [
      message("b1", .bot, "On it.", at: 0),
      message(sentID.uuidString.lowercased(), .user, "Sent after Scout", at: 20),
    ]

    let ids = try rows(
      [.assistant(AssistantMessage(turn: longJob)), .user(scout), .assistant(AssistantMessage(turn: scoutReply))],
      conversation)

    #expect(ids.filter(isFeedRow) == [.botMessage("b1"), .eventMarker(scout.id), .message(sentID)])
  }

  private func rows(
    _ settled: [ConversationItem], _ messages: [TranscriptBotMessage], pending: UserMessage? = nil
  ) throws -> [TranscriptPresentationRow.ID] {
    let input = TranscriptProjectionInput(
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
      botConversation: TranscriptBotConversation(messages: messages, isWorking: false)
    )
    return try TranscriptRowProjectionCache.project(input, options: options).map(\.id)
  }

  private func askingTurn(endedAt seconds: TimeInterval) -> AssistantTurn {
    var turn = AssistantTurn(startedAt: at(seconds - 4), endedAt: at(seconds))
    turn.setupRequests = [TranscriptSetupRequest(id: "cu", kind: .computerUse, state: .setUp)]
    let request = QuestionRequest(questionId: "q", questions: [QuestionSpec(id: "db", question: "Which database?")])
    turn.interactions = TranscriptInteractions([.init(id: "q", content: .question(.init(request: request)))])
    return turn
  }

  private func event(from agent: String, at seconds: TimeInterval) -> UserMessage {
    UserMessage(
      text: "<codevisor-event type=\"session.turn_ended\" agentId=\"\(agent)\">\ndone\n</codevisor-event>",
      isEvent: true, sentAt: at(seconds))
  }

  private func message(
    _ id: String, _ sender: TranscriptBotMessage.Sender, _ text: String, at seconds: TimeInterval
  ) -> TranscriptBotMessage {
    TranscriptBotMessage(id: id, sender: sender, text: text, sentAt: at(seconds))
  }

  private func at(_ seconds: TimeInterval) -> Date {
    start.addingTimeInterval(seconds)
  }

  private func isFeedRow(_ id: TranscriptPresentationRow.ID) -> Bool {
    switch id {
    case .botMessage, .eventMarker, .message: true
    default: false
    }
  }
}
