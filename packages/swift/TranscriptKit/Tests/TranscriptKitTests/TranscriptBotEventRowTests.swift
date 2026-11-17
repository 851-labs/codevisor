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

  @Test(
    "A bot conversation shows outside events and messages, and leaves out its agents' statuses and Codevisor bookkeeping",
    arguments: [
      ("plugin.event", true), ("thread.message", true), ("execution.job_finished", true),
      ("exec.task_finished", true), ("harness.task_finished", true), ("session.restarted", true),
      ("session.usage_limit_reset", true), ("question.answered", true), ("bot.created", true),
      ("session.turn_ended", false), ("session.waiting_for_user", false), ("session.errored", false),
      ("session.user_message", false), ("bot.handoff", false), ("bot.instructions_updated", false),
      ("bot.projects_changed", false),
    ])
  func showsOnlyEventsWithTheirOwnRow(type: String, shows: Bool) throws {
    let event = UserMessage(text: agentEvent(type, "a1"), isEvent: true)

    let rows = try project([.user(event)], TranscriptBotConversation(messages: [], isWorking: false))

    #expect(rows.contains { $0.id == .eventMarker(event.id) } == shows)
  }

  @Test func keepsTheOtherEventsOfAPromptAndMessagesFromOtherAgents() throws {
    let mixed = UserMessage(
      text: [
        agentEvent("session.turn_ended", "a1", #"stopKind="usageLimit""#), agentEvent("session.user_message", "a1"),
        agentEvent("plugin.event", "a1", #"plugin="Slack""#),
      ].joined(separator: "\n"),
      isEvent: true)
    let plain = UserMessage(text: " continue ", isEvent: true)
    let sent = UserMessage(text: "Two nits on the PR", sentByAgentId: "a5")
    var wake = AssistantTurn(entries: [.text(id: "work", markdown: "Reading the results")])
    wake.startedAt = start.addingTimeInterval(30)
    let conversation = TranscriptBotConversation(
      messages: [message("b1", "Started helpers.", at: 5), message("b2", "All done.", at: 32)],
      isWorking: false
    )

    let rows = try project(
      [.user(mixed), .user(plain), .user(sent), .assistant(AssistantMessage(turn: wake))], conversation)

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
