import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  private func startedTurnModel(
    now: @escaping @Sendable () -> Date
  ) -> (SessionModel, UUID) {
    let sessionId = UUID()
    let model = SessionModel(
      serverTransport: ServerSessionTransport(
        client: FakeSessionServerClient(sessionId: sessionId), sessionId: sessionId),
      sessionId: sessionId.uuidString,
      now: now
    )
    return (model, sessionId)
  }

  private func activeTurn(_ model: SessionModel) -> AssistantTurn? {
    guard case let .assistant(message) = model.activeItem else { return nil }
    return message.turn
  }

  @Test("The turn-started event stamps a start time on a turn that has none")
  func turnStartedBackfillsStartedAt() {
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let (model, _) = startedTurnModel(now: { stamp })
    let itemId = UUID()
    model.setConversation([
      .assistant(AssistantMessage(id: itemId, turn: AssistantTurn(isGenerating: true)))
    ])
    #expect(activeTurn(model)?.startedAt == nil)

    model.apply(.assistantItemStarted(itemId))
    #expect(activeTurn(model)?.startedAt == stamp)
  }

  @Test("The turn-started event never overwrites a start time already held")
  func turnStartedKeepsExistingStartedAt() {
    let original = Date(timeIntervalSince1970: 1_700_000_000)
    let later = Date(timeIntervalSince1970: 1_700_000_030)
    let (model, _) = startedTurnModel(now: { later })
    let itemId = UUID()
    model.setConversation([
      .assistant(
        AssistantMessage(id: itemId, turn: AssistantTurn(isGenerating: true, startedAt: original)))
    ])

    model.apply(.assistantItemStarted(itemId))
    #expect(activeTurn(model)?.startedAt == original)
  }

  @Test("The server's later start, stamped once the harness began, cannot move a turn's start past its send")
  func serverStartCannotMoveTheSendStartLater() {
    let sent = Date(timeIntervalSince1970: 1_700_000_000)
    let harnessStarted = sent.addingTimeInterval(4)
    let (model, _) = startedTurnModel(now: { sent })
    let itemId = UUID()
    model.setConversation([
      .assistant(AssistantMessage(id: itemId, turn: AssistantTurn(isGenerating: true, startedAt: sent)))
    ])

    model.setConversation([
      .assistant(AssistantMessage(id: itemId, turn: AssistantTurn(isGenerating: true, startedAt: harnessStarted)))
    ])
    #expect(activeTurn(model)?.startedAt == sent)
  }

  @Test("A snapshot with no start time cannot reset a timer already counting")
  func snapshotDoesNotClobberLocalStartedAt() {
    let original = Date(timeIntervalSince1970: 1_700_000_000)
    let (model, _) = startedTurnModel(now: { original })
    let itemId = UUID()
    model.setConversation([
      .assistant(
        AssistantMessage(id: itemId, turn: AssistantTurn(isGenerating: true, startedAt: original)))
    ])

    model.setConversation([
      .assistant(AssistantMessage(id: itemId, turn: AssistantTurn(isGenerating: true)))
    ])
    #expect(activeTurn(model)?.startedAt == original)
  }

  @Test("A different turn never inherits the previous turn's start time")
  func snapshotDoesNotFabricateStartedAtAcrossTurns() {
    let original = Date(timeIntervalSince1970: 1_700_000_000)
    let (model, _) = startedTurnModel(now: { original })
    model.setConversation([
      .assistant(
        AssistantMessage(turn: AssistantTurn(isGenerating: true, startedAt: original)))
    ])

    model.setConversation([
      .assistant(AssistantMessage(turn: AssistantTurn(isGenerating: true)))
    ])
    #expect(activeTurn(model)?.startedAt == nil)
  }

  @Test("A server copy of the turn keeps where the model reasoned, so its tool groups don't merge as it settles")
  func snapshotKeepsReasoningBreaks() {
    let (model, _) = startedTurnModel(now: { Date(timeIntervalSince1970: 1_700_000_000) })
    let itemId = UUID()
    var live = AssistantTurn(isGenerating: true)
    live.callsAfterReasoning = ["second"]
    model.setConversation([.assistant(AssistantMessage(id: itemId, turn: live))])

    model.setConversation([.assistant(AssistantMessage(id: itemId, turn: AssistantTurn(isGenerating: true)))])
    #expect(activeTurn(model)?.callsAfterReasoning == ["second"])

    model.setConversation([.assistant(AssistantMessage(turn: AssistantTurn(isGenerating: true)))])
    #expect(activeTurn(model)?.callsAfterReasoning.isEmpty == true)
  }
}
