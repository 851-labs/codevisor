import ScreenSharingV2

public enum ScreenSharingConnectionDeadlines {
  public static let stillConnectingHint = ScreenSharingConnectStage.stillConnectingAfter
  public static let firstFrame = ScreenSharingConnectStage.deadline
  public static let reconnectingLinkGrace = ScreenSharingConnectStage.reconnectingTunnelGrace
  public static let heartbeatInterval: Duration = .seconds(8)
  public static let failedHeartbeats: Duration = .seconds(25)
  public static let controlRequest: Duration = .seconds(3)
  public static let unseenDebounce: Duration = .seconds(2)
  public static let linger: Duration = .seconds(60)
  public static let stableLive: Duration = .seconds(30)
}
