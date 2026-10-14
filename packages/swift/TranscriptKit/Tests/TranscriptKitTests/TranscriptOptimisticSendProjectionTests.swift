import Foundation
import Testing
import ACPKit
import CodevisorProtocol
@testable import TranscriptKit

@Suite("Optimistic first-send projection")
struct TranscriptOptimisticSendProjectionTests {
  @Test func optimisticSendWaitsOnTheHarnessOnceSetupSucceeds() throws {
    let user = UserMessage(text: "hi")
    var worktree = SessionSetupPhase.worktree()

    let running = try TranscriptRowProjectionCache.project(
      makeInput(pending: user, setup: [worktree]), options: .init(includesConnectingRow: false))
    #expect(running.map(\.id) == [.message(user.id), .setup])

    worktree.succeed()
    let ready = try TranscriptRowProjectionCache.project(
      makeInput(pending: user, setup: [worktree]), options: .init(includesConnectingRow: false))
    #expect(ready.map(\.id) == [.message(user.id), .setup, .startingAgent])
    #expect(ready[2].estimatedHeight == TranscriptAssistantRowProjection.activityRowEstimatedHeight)

    let connecting = try TranscriptRowProjectionCache.project(
      makeInput(pending: user, setup: [worktree], status: .connecting("Starting Codex…")),
      options: .init(includesConnectingRow: true))
    #expect(connecting.map(\.id) == [.message(user.id), .setup, .startingAgent])

    let noSetup = try TranscriptRowProjectionCache.project(
      makeInput(pending: user), options: .init(includesConnectingRow: false))
    #expect(noSetup.map(\.id) == [.message(user.id), .startingAgent])

    var failed = SessionSetupPhase.worktree()
    failed.fail(message: "boom")
    let afterFailure = try TranscriptRowProjectionCache.project(
      makeInput(pending: user, setup: [failed]), options: .init(includesConnectingRow: false))
    #expect(!afterFailure.contains { $0.id == .startingAgent })

    let failedStatus = try TranscriptRowProjectionCache.project(
      makeInput(pending: user, setup: [worktree], status: .failed("no agent")),
      options: .init(includesConnectingRow: false))
    #expect(!failedStatus.contains { $0.id == .startingAgent })

    let withoutPending = try TranscriptRowProjectionCache.project(
      makeInput(setup: [worktree]), options: .init(includesConnectingRow: false))
    #expect(!withoutPending.contains { $0.id == .startingAgent })
  }

  @Test func liveActiveTurnReplacesTheOptimisticHarnessPlaceholderInPlace() throws {
    let user = UserMessage(text: "hi")
    var worktree = SessionSetupPhase.worktree()
    worktree.succeed()
    let assistant = AssistantMessage(turn: AssistantTurn(isGenerating: true))
    let rows = try TranscriptRowProjectionCache.project(
      makeInput(settled: [.user(user)], pending: user, active: .assistant(assistant), setup: [worktree]),
      options: .init(includesConnectingRow: false))
    #expect(rows.map(\.id) == [.message(user.id), .setup, .active(assistant.id)])
    #expect(rows[2].estimatedHeight == TranscriptAssistantRowProjection.activityRowEstimatedHeight)
  }

  private func makeInput(
    settled: [ConversationItem] = [],
    pending: UserMessage? = nil,
    active: ConversationItem? = nil,
    setup: [SessionSetupPhase] = [],
    status: TranscriptProjectionInput.ConnectionStatus = .idle
  ) -> TranscriptProjectionInput {
    TranscriptProjectionInput(
      settledConversation: settled,
      pendingUserMessage: pending,
      activeItem: active,
      setupPhases: setup,
      waitingBackgroundTaskDescription: nil,
      waitingHarnessUpdateName: nil,
      isLoadingInitialHistory: false,
      serverWaitMessage: nil,
      sessionErrorMessage: nil,
      status: status
    )
  }
}
