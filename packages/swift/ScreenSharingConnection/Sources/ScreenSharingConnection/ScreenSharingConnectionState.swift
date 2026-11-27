import ScreenSharingV2

public enum ScreenSharingConnectionState: Equatable, Sendable {
  case off
  case connecting(ScreenSharingConnectStage)
  case live
  case reconnecting
  case failed(ScreenSharingFailureReason)

  public var isConnecting: Bool {
    if case .connecting = self { true } else { false }
  }

  public var isUnderway: Bool {
    isConnecting || self == .live || self == .reconnecting
  }
}
