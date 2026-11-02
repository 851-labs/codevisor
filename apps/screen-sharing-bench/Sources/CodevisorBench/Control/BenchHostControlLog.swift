import ScreenSharing

@MainActor
final class BenchHostControlLog {
  var requests = 0
  var injectedEvents = 0
  private var grants = 0
  private var denials: [String] = []
  private var revocations: [String] = []

  func record(sent message: ScreenSharingControlMessage) {
    switch message {
    case .grant: grants += 1
    case .denied(_, let reason): denials.append(reason)
    case .revoked(_, let reason): revocations.append(reason)
    default: break
    }
  }

  var summary: BenchHostControlSummary {
    BenchHostControlSummary(
      requests: requests, grants: grants, denials: denials, revocations: revocations, injectedEvents: injectedEvents)
  }
}
