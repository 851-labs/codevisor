import ACPKit
import Foundation
import Testing

@testable import TranscriptKit

@Suite("Steered message projection")
struct TranscriptSteerBubbleProjectionTests {
  @Test("A waiting steer is a bubble under the live turn with its Waiting on tool row, until it is delivered")
  func waitingSteerProjectsBelowTheLiveTurn() throws {
    let first = UserMessage(text: "run the checks")
    let steer = UserMessage(text: "also bump the version")
    let later = UserMessage(text: "and update the changelog")
    let running = AssistantMessage(turn: AssistantTurn(isGenerating: true))

    let waiting = try TranscriptRowProjectionCache.project(
      input(
        settled: [.user(first)], active: .assistant(running), outgoing: [steer, later],
        deliveries: [steer.id: .awaitingStep]),
      options: .init(includesConnectingRow: false))
    let delivered = try TranscriptRowProjectionCache.project(
      input(settled: [.user(first), .user(steer)], active: .assistant(running), outgoing: [later]),
      options: .init(includesConnectingRow: false))

    #expect(
      waiting.map(\.id) == [
        .message(first.id), .active(running.id), .message(steer.id), .delivery(steer.id), .message(later.id),
      ])
    #expect(waiting[3].content == .delivery(steer.id, .awaitingStep))
    #expect(!delivered.contains { $0.id == .delivery(steer.id) })
    #expect(delivered.contains { $0.id == .message(steer.id) })
  }

  private func input(
    settled: [ConversationItem],
    active: ConversationItem,
    outgoing: [UserMessage],
    deliveries: [UUID: TranscriptDelivery] = [:]
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
      outgoingMessages: outgoing,
      deliveries: deliveries
    )
  }
}
