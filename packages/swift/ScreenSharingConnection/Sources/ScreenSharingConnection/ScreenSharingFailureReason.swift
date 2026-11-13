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
  case permissionMissing
  case updateNeeded
  case networkBlocked
  case noVideo
  case keptDropping
  case unclassified(message: String?)

  init?(hostCode: String?, holderName: String?) {
    switch hostCode {
    case "taken-over": self = .takenOver(by: holderName)
    case "in-use": self = .inUse(by: holderName)
    case "stopped-on-host": self = .stoppedOnHost
    case "display-asleep": self = .displayAsleep
    case "session-switched": self = .sessionSwitched
    case "no-display": self = .noDisplay
    case "permission-missing": self = .permissionMissing
    case "update-needed": self = .updateNeeded
    default: return nil
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
