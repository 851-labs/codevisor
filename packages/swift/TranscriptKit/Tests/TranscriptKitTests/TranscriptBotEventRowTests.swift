import Foundation
import Testing

@testable import TranscriptKit

struct TranscriptBotEventRowTests {
  private let start = Date(timeIntervalSince1970: 1_792_324_800)

  @Test func showsTheEventThatWokeTheBotRightBeforeTheReplyItStarted() throws {
    let event = UserMessage(
      text: "<codevisor-event type=\"plugin.event\" plugin=\"Slack\">\nping\n</codevisor-event>", isEvent: true)
    var wake = AssistantTurn(entries: [.text(id: "work", markdown: "Reading the message")])
    wake.startedAt = start.addingTimeInterval(30)
    let conversation = TranscriptBotConversation(
      messages: [message("b1", "Watching Slack.", at: 5), message("b2", "Someone said ping.", at: 32)],
      isWorking: false
    )

    let rows = try project([.user(event), .assistant(AssistantMessage(turn: wake))], conversation)

    #expect(rows.map(\.id).filter(isFeedRow) == [.botMessage("b1"), .eventMarker(event.id), .botMessage("b2")])
    #expect(
      rows.contains { row in
        if case .eventMarker(_, inBotConversation: true) = row.content { return true }
        return false
      })
  }

  @Test func leavesOutItsAgentsFinishingPausingErroringAndWaiting() throws {
    let statuses = UserMessage(
      text: [
        agentEvent("session.turn_ended", "a1"), agentEvent("session.turn_ended", "a2", #"stopKind="usageLimit""#),
        agentEvent("session.errored", "a3"), agentEvent("session.waiting_for_user", "a4", #"kind="question""#),
      ].joined(separator: "\n"),
      isEvent: true)
    let mixed = UserMessage(
      text: agentEvent("session.turn_ended", "a1") + "\n" + agentEvent("plugin.event", "a1", #"plugin="Slack""#),
      isEvent: true)
    let sent = UserMessage(text: "Two nits on the PR", sentByAgentId: "a5")
    var wake = AssistantTurn(entries: [.text(id: "work", markdown: "Reading the results")])
    wake.startedAt = start.addingTimeInterval(30)
    let conversation = TranscriptBotConversation(
      messages: [message("b1", "Started helpers.", at: 5), message("b2", "All done.", at: 32)],
      isWorking: false
    )

    let rows = try project(
      [.user(statuses), .user(mixed), .user(sent), .assistant(AssistantMessage(turn: wake))], conversation)

    #expect(
      rows.map(\.id).filter(isFeedRow) == [
        .botMessage("b1"), .eventMarker(mixed.id), .eventMarker(sent.id), .botMessage("b2"),
      ])
    #expect(eventTypes(rows, for: mixed.id) == ["plugin.event"])
  }

  @Test func keepsAgentStatusRowsInTheFullTranscript() throws {
    let event = UserMessage(text: agentEvent("session.turn_ended", "a1"), isEvent: true)

    let rows = try TranscriptRowProjectionCache.project(
      input(settled: [.user(event)], TranscriptBotConversation(messages: [], isWorking: false)),
      options: .init(includesConnectingRow: false)
    )

    #expect(rows.map(\.id) == [.eventMarker(event.id)])
  }

  private func project(
    _ settled: [ConversationItem], _ conversation: TranscriptBotConversation
  ) throws
    -> [TranscriptPresentationRow]
  {
    try TranscriptRowProjectionCache.project(
      input(settled: settled, conversation),
      options: .init(includesConnectingRow: false, presentsBotConversation: true)
    )
  }

  private func isFeedRow(_ id: TranscriptPresentationRow.ID) -> Bool {
    switch id {
    case .botMessage, .eventMarker: true
    default: false
    }
  }

  private func agentEvent(_ type: String, _ agentID: String, _ attributes: String = "") -> String {
    #"<codevisor-event type="\#(type)" agentId="\#(agentID)" \#(attributes)>"# + "\ndone\n</codevisor-event>"
  }

  private func eventTypes(_ rows: [TranscriptPresentationRow], for id: UUID) -> [String]? {
    rows.lazy.compactMap { row -> [String]? in
      guard case let .eventMarker(marker, _) = row.content, marker.messageID == id else { return nil }
      return marker.events.map(\.type)
    }.first
  }

  private func message(_ id: String, _ text: String, at seconds: TimeInterval) -> TranscriptBotMessage {
    TranscriptBotMessage(id: id, sender: .bot, text: text, sentAt: start.addingTimeInterval(seconds))
  }

  private func input(
    settled: [ConversationItem], _ conversation: TranscriptBotConversation
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
      status: .idle,
      botConversation: conversation
    )
  }
}
