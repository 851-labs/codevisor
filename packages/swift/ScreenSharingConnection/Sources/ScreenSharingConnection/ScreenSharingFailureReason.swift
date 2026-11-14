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
  case unsupportedOnThisDevice
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

  public func sentence(on machine: String) -> String {
    switch self {
    case .cantReach: "Can't reach \(machine). Check that it's awake and online."
    case .takenOver(let holder?): "Now viewing on \(holder)."
    case .inUse(let holder?): "In use on \(holder)."
    case .takenOver(nil), .inUse(nil), .inUseOldHost: "\(machine) is in use on another device."
    case .stoppedOnHost: "Sharing was stopped on \(machine)."
    case .displayAsleep: "\(machine)'s display is asleep."
    case .sessionSwitched: "Another user is logged in on \(machine)."
    case .noDisplay: "\(machine) has no display to share."
    case .noWorkspace: "Open a chat on \(machine) to view its desktop."
    case .unsupportedOnThisDevice: "\(machine)'s desktop can only be viewed from a Mac."
    case .permissionMissing: "Allow Codevisor to record the screen on \(machine)."
    case .updateNeeded: "Update Codevisor on \(machine)."
    case .networkBlocked: "Couldn't open a video connection to \(machine)."
    case .noVideo: "Connected, but \(machine) sent no picture."
    case .keptDropping: "The connection to \(machine) keeps dropping."
    case .unclassified(let message): message ?? "\(machine) can't share its screen right now."
    }
  }

  var isDecidedByHost: Bool {
    switch self {
    case .takenOver, .inUse, .inUseOldHost, .stoppedOnHost, .displayAsleep, .sessionSwitched: true
    default: false
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
