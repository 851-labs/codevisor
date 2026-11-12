import ACPKit
import CodevisorProtocol
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptEventProjectionTests {
  @Test("An event prompt projects one event row with its parsed type, attributes, and body instead of a bubble")
  func eventPromptsProjectEventRows() throws {
    let typed = UserMessage(text: "Start a slow helper")
    let event = UserMessage(
      text:
        "<codevisor-event type=\"execution.job_finished\" jobId=\"94bf06a62c\" description=\"Say &quot;hi&quot;\">\nDone\n</codevisor-event>",
      isEvent: true
    )

    let rows = try project([.user(typed), .assistant(reply("Running.")), .user(event), .assistant(reply("Done."))])

    #expect(rows.filter(\.isUserMessage).map(\.id) == [.message(typed.id)])
    #expect(
      events(in: rows, for: event.id) == [
        TranscriptEvent(
          type: "execution.job_finished", attributes: ["jobId": "94bf06a62c", "description": "Say \"hi\""], body: "Done"
        )
      ])
  }

  @Test("A message another agent sent projects as a session.message event from that agent")
  func agentMessagesProjectEventRows() throws {
    let message = UserMessage(text: "Two nits on the PR", sentByAgentId: "agent-1", sentByAgentMachineId: "machine-1")

    let rows = try project([.user(message), .assistant(reply("Fixed."))])

    #expect(rows.filter(\.isUserMessage).isEmpty)
    #expect(
      events(in: rows, for: message.id) == [
        TranscriptEvent(
          type: "session.message", attributes: ["from": "agent-1", "fromMachineId": "machine-1"],
          body: "Two nits on the PR")
      ])
  }

  @Test("An event prompt holding several events, or none in the envelope format, still projects one row")
  func eventPromptShapes() throws {
    let pair = UserMessage(
      text:
        "<codevisor-event type=\"a\">\none\n</codevisor-event>\n\n<codevisor-event type=\"b\">\ntwo\n</codevisor-event>",
      isEvent: true)
    let plain = UserMessage(text: " continue ", isEvent: true)

    let rows = try project([.user(pair), .user(plain)])

    #expect(events(in: rows, for: pair.id)?.map(\.type) == ["a", "b"])
    #expect(events(in: rows, for: plain.id) == [TranscriptEvent(type: "unknown", body: "continue")])
  }

  @Test("A transcript that opens with an event prompt places setup after it, like a typed prompt")
  func openingEventPromptKeepsSetupPlacement() throws {
    let event = UserMessage(text: "<codevisor-event type=\"session.turn_ended\">\n</codevisor-event>", isEvent: true)
    let setup = [SessionSetupPhase.worktree(startedAt: Date(timeIntervalSince1970: 0))]

    let rows = try project([.user(event), .assistant(reply("Done."))], setup: setup)

    #expect(rows.prefix(2).map(\.id) == [.eventMarker(event.id), .setup])
  }

  @Test("A question the user replied past instead of answering projects no row")
  func repliedPastQuestionsAreInvisible() throws {
    let request = QuestionRequest(questionId: "q", questions: [QuestionSpec(id: "db", question: "Which database?")])
    let plain = reply("One question first.")
    var asked = plain
    asked.turn.interactions = TranscriptInteractions([
      .init(id: "q", content: .question(.init(request: request, answer: .init(outcome: .replied))))
    ])

    #expect(try project([.assistant(asked)]).map(\.id) == project([.assistant(plain)]).map(\.id))
  }

  private func events(in rows: [TranscriptPresentationRow], for id: UUID) -> [TranscriptEvent]? {
    for row in rows {
      if case let .eventMarker(marker, _) = row.content, marker.messageID == id { return marker.events }
    }
    return nil
  }

  private func reply(_ text: String) -> AssistantMessage {
    AssistantMessage(turn: AssistantTurn(entries: [.text(id: "answer", markdown: text)]))
  }

  private func project(
    _ settled: [ConversationItem],
    setup: [SessionSetupPhase] = []
  ) throws -> [TranscriptPresentationRow] {
    try TranscriptRowProjectionCache.project(
      TranscriptProjectionInput(
        settledConversation: settled,
        pendingUserMessage: nil,
        activeItem: nil,
        setupPhases: setup,
        waitingBackgroundTaskDescription: nil,
        waitingHarnessUpdateName: nil,
        isLoadingInitialHistory: false,
        serverWaitMessage: nil,
        sessionErrorMessage: nil,
        status: .idle
      ),
      options: .init(includesConnectingRow: false)
    )
  }
}
