import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

/// The elapsed "Working for Xs" label reads `AssistantTurn.startedAt`, and
/// renders a hard 0 when it is nil. The server creates the assistant row when
/// the prompt is accepted but only stamps `started_at` once the harness
/// reports the turn started — so a client that opens the session during
/// harness startup receives a generating turn with no start time and shows a
/// frozen "Working for 0s" until some later full snapshot happens to carry
/// the value, at which point it jumps to the true elapsed time.
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
    // A snapshot taken during harness startup: generating, no start time.
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

  @Test("A snapshot with no start time cannot reset a timer already counting")
  func snapshotDoesNotClobberLocalStartedAt() {
    let original = Date(timeIntervalSince1970: 1_700_000_000)
    let (model, _) = startedTurnModel(now: { original })
    let itemId = UUID()
    model.setConversation([
      .assistant(
        AssistantMessage(id: itemId, turn: AssistantTurn(isGenerating: true, startedAt: original)))
    ])

    // A mid-turn reconcile that raced the server's `started_at` write.
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

    // A genuinely new turn: carrying the old start time would invent an
    // elapsed duration that never happened.
    model.setConversation([
      .assistant(AssistantMessage(turn: AssistantTurn(isGenerating: true)))
    ])
    #expect(activeTurn(model)?.startedAt == nil)
  }
}
