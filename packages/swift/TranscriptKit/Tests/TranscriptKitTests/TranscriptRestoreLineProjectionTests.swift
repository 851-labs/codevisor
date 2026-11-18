import ACPKit
import CodevisorProtocol
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptRestoreLineProjectionTests {
  @Test("Each restore's setup line sits after the last message from before it, and the first setup line stays put")
  func restoreLinesKeepTheirPlace() throws {
    let first = UserMessage(text: "Remember PAPAYA")
    let reply = AssistantMessage(turn: AssistantTurn(entries: [.text(id: "a", markdown: "OK")]))
    let later = UserMessage(text: "What was it?")
    let answer = AssistantMessage(turn: AssistantTurn(entries: [.text(id: "b", markdown: "PAPAYA")]))
    var created = SessionSetupPhase(
      id: "project.setup:p", activeTitle: "Setting up project", completedTitle: "Set up project",
      failedTitle: "Could not set up project")
    created.succeed(durationMs: 500)
    let restores = [reply.id, answer.id].map { anchor in
      var restore = SessionSetupPhase(
        id: "sandbox.restore:\(anchor)", activeTitle: "Restoring sandbox", completedTitle: "Restored sandbox",
        failedTitle: "Could not restore sandbox")
      restore.succeed(durationMs: 40_000)
      restore.followsItemId = anchor
      return restore
    }

    let rows = try TranscriptRowProjectionCache.project(
      TranscriptProjectionInput(
        settledConversation: [.user(first), .assistant(reply), .user(later), .assistant(answer)],
        pendingUserMessage: nil, activeItem: nil, setupPhases: [created] + restores,
        waitingBackgroundTaskDescription: nil, waitingHarnessUpdateName: nil, isLoadingInitialHistory: false,
        serverWaitMessage: nil, sessionErrorMessage: nil, status: .idle),
      options: .init(includesConnectingRow: false))
    let setupRows = rows.compactMap { row -> String? in
      guard case let .setup(phases) = row.content else { return nil }
      return "\(row.id): \(phases.map(\.completedTitle).joined(separator: ","))"
    }
    let order = rows.map(\.id)

    #expect(
      setupRows == [
        "setup: Set up project", "setupAfter(\(reply.id)): Restored sandbox",
        "setupAfter(\(answer.id)): Restored sandbox",
      ])
    #expect(order.firstIndex(of: .setup)! < order.firstIndex(of: .setupAfter(reply.id))!)
    #expect(order.firstIndex(of: .setupAfter(reply.id))! < order.firstIndex(of: .message(later.id))!)
    #expect(order.firstIndex(of: .message(later.id))! < order.firstIndex(of: .setupAfter(answer.id))!)
  }
}
