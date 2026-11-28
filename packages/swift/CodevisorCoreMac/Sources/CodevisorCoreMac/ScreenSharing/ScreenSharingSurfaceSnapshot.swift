import CodevisorClient
import CoreGraphics
import ScreenSharingConnection

public struct ScreenSharingSurfaceSnapshot: Equatable, Sendable {
  public var connection = ScreenSharingConnectionState.off
  public var isTakingLong = false
  public var hostNotice: String?
  public var displays: [ServerScreenSharingDisplay] = []
  public var unavailableDisplays: [ServerScreenSharingUnavailableDisplay] = []
  public var displayId: String?
  public var displaySwitch: ScreenSharingDisplaySwitch?
  public var endpoint: ScreenSharingViewerEndpoint?
  public var pictureSize: CGSize?
  public var control: ScreenSharingControlStatus?
  public var mode = ScreenSharingViewer.InteractionMode.control
  public var dynamicResolution = false

  public init() {}

  public var hasControl: Bool { control?.phase == .controlling }
}
