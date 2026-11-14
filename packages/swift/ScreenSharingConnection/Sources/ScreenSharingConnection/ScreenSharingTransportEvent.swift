import CodevisorClient
import ScreenSharing
import ScreenSharingV2

public enum ScreenSharingTransportEvent {
  case entered(ScreenSharingConnectStage)
  case opened(any ScreenSharingViewingSession)
  case sharing(display: ServerScreenSharingDisplay?, displays: [ServerScreenSharingDisplay])
  case notice(String?)
}
