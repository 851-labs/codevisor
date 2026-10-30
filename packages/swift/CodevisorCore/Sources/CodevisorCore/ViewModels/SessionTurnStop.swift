import Foundation
import ACPKit

struct SessionTurnStop {
  var stopReason: StopReason?
  var outcome: TranscriptReducer.TurnOutcome
  var detail: String?
  var kind: String?
  var retryable = false

  var parksQuestion: Bool { kind == "pausedForUpdate" || kind == "interrupted" }

  static func finished(_ stopReason: StopReason, detail: String?, kind: String?, retryable: Bool) -> Self {
    let outcome: TranscriptReducer.TurnOutcome = stopReason == .cancelled ? .cancelled : .completed
    return Self(stopReason: stopReason, outcome: outcome, detail: detail, kind: kind, retryable: retryable)
  }

  static func failed(_ detail: String, kind: String? = nil, retryable: Bool = false) -> Self {
    Self(stopReason: nil, outcome: .failed, detail: detail, kind: kind, retryable: retryable)
  }

  func close(_ turn: inout AssistantTurn, endedAt: Date) {
    turn.isGenerating = false
    turn.isThinking = false
    turn.retryStatus = nil
    turn.stopReason = stopReason
    turn.stopDetail = detail
    turn.stopKind = kind
    turn.retryable = retryable
    turn.endedAt = endedAt
    TranscriptReducer.settleToolCalls(&turn, outcome: outcome)
  }
}
