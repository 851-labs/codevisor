import Foundation
import Testing
import ACPKit
@testable import TranscriptKit

@Suite("Duplicate transcript rows")
struct TranscriptDuplicateRowProjectionTests {
  @Test func aStreamingMessageThatIsAlsoSettledProjectsOnlyItsActiveRow() throws {
    let user = UserMessage(text: "hi")
    let reply = AssistantMessage(turn: AssistantTurn(entries: [.text(id: "answer", markdown: "Hello")]))

    let rows = try TranscriptRowProjectionCache.project(
      makeInput(settled: [.user(user), .assistant(reply)], active: .assistant(reply)),
      options: .init(includesConnectingRow: false))

    #expect(rows.map(\.id) == [.message(user.id), .active(reply.id)])
  }

  @Test func anOutgoingMessageThatIsAlreadySettledProjectsOnce() throws {
    let user = UserMessage(text: "hi")

    let rows = try TranscriptRowProjectionCache.project(
      makeInput(settled: [.user(user)], outgoing: [user]), options: .init(includesConnectingRow: false))

    #expect(rows.map(\.id) == [.message(user.id)])
  }

  private func makeInput(
    settled: [ConversationItem], active: ConversationItem? = nil, outgoing: [UserMessage] = []
  ) -> TranscriptProjectionInput {
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
      outgoingMessages: outgoing
    )
  }
}
