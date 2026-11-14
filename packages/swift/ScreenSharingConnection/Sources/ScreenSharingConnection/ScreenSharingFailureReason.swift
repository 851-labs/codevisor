import CodevisorClient
import ScreenSharingV2

public enum ScreenSharingFailureReason: Equatable, Sendable {
  case cantReach
  case takenOver(by: String?)
  case inUse(by: String?)
  case inUseOldHost
  case stoppedOnHost
  case displayAsleep
  case sessionSwitched
  case noDisplay
  case noWorkspace
  case permissionMissing
  case updateNeeded
  case networkBlocked
  case noVideo
  case keptDropping
  case unclassified(message: String?)

  init?(hostReason: ServerScreenSharingReason?, holderName: String?) {
    switch hostReason {
    case .takenOver?: self = .takenOver(by: holderName)
    case .inUse?: self = .inUse(by: holderName)
    case .stoppedOnHost?: self = .stoppedOnHost
    case .displayAsleep?: self = .displayAsleep
    case .sessionSwitched?: self = .sessionSwitched
    case .noDisplay?: self = .noDisplay
    case .permissionMissing?: self = .permissionMissing
    case .updateNeeded?: self = .updateNeeded
    default: return nil
    }
  }

  var yieldsToAnOpen: Bool {
    switch self {
    case .inUse, .stoppedOnHost, .displayAsleep, .sessionSwitched: true
    default: false
    }
  }

  static func timedOut(at stage: ScreenSharingConnectStage) -> Self {
    switch stage {
    case .reachingHost, .startingHost: .cantReach
    case .connectingMedia, .handshake: .networkBlocked
    case .waitingForVideo: .noVideo
    }
  }
}
