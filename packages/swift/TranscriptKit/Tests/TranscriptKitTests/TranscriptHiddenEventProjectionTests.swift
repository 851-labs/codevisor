import CodevisorProtocol
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptHiddenEventProjectionTests {
  @Test("Event prompts project to no rows and leave the surrounding turns laid out unchanged")
  func eventPromptsAreInvisible() throws {
    let typed = UserMessage(text: "Start a slow helper")
    let first = reply("It is running as job 94bf06a62c.")
    let event = UserMessage(
      text: "<codevisor-event type=\"execution.job_finished\" jobId=\"94bf06a62c\">\nDone\n</codevisor-event>",
      isEvent: true
    )
    let second = reply("The background job finished.")

    let withEvent = try project([.user(typed), .assistant(first), .user(event), .assistant(second)])
    let withoutEvent = try project([.user(typed), .assistant(first), .assistant(second)])

    #expect(withEvent == withoutEvent)
    #expect(!withEvent.contains { $0.id.messageID == event.id })
    #expect(withEvent.filter(\.isUserMessage).map(\.id) == [.message(typed.id)])
    #expect(withEvent.contains { $0.id == .assistantWorkedHeader(first.id, .planning) })
    #expect(withEvent.contains { $0.id == .assistantWorkedHeader(second.id, .planning) })
  }

  @Test("A transcript that opens with an event prompt still places setup before the first reply")
  func openingEventPromptKeepsSetupPlacement() throws {
    let event = UserMessage(text: "<codevisor-event type=\"session.turn_ended\">\n</codevisor-event>", isEvent: true)
    let answer = reply("Done.")
    let setup = [SessionSetupPhase.worktree(startedAt: Date(timeIntervalSince1970: 0))]

    let rows = try project([.user(event), .assistant(answer)], setup: setup)

    #expect(rows.first?.id == .setup)
    #expect(!rows.contains { $0.id.messageID == event.id })
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
