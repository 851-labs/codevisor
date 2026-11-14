import ScreenSharingV2

public enum ScreenSharingConnectionState: Equatable, Sendable {
  case off
  case connecting(ScreenSharingConnectStage)
  case live
  case reconnecting
  case failed(ScreenSharingFailureReason)
}
