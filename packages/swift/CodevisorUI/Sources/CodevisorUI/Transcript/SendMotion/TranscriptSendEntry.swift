import CodevisorCore
import QuartzCore

@MainActor
struct TranscriptSendEntry {
  enum Phase {
    case awaitingRow
    case awaitingFlight(mountedAt: CFTimeInterval)
    case flying(TranscriptSendFlight)
    case lifting
    case landed
  }

  let request: UserSendAnimationRequest
  let rowKey: String
  let startedAt: CFTimeInterval
  var phase: Phase
  var isClaimed = false
  var didNotifyStart = false
  var didNotifyCompletion = false

  var isLanded: Bool {
    if case .landed = phase { return true }
    return false
  }

  var hidesRow: Bool {
    switch phase {
    case .awaitingFlight, .flying: true
    case .awaitingRow, .lifting, .landed: false
    }
  }

  var ridesCarrier: Bool {
    if case let .flying(flight) = phase { return flight.ridesCarrier }
    return false
  }
}
