import CodevisorClient
import ScreenSharingConnection

public struct ScreenSharingSurfaceSnapshot: Equatable, Sendable {
  public enum Picture: Equatable, Sendable {
    case none
    case here(ScreenSharingViewerEndpoint)
    case elsewhere(ScreenSharingViewerEndpoint)
  }

  public var connection = ScreenSharingConnectionState.off
  public var isTakingLong = false
  public var hostNotice: String?
  public var displays: [ServerScreenSharingDisplay] = []
  public var displayId: String?
  public var picture = Picture.none

  public init() {}

  public var endpoint: ScreenSharingViewerEndpoint? {
    if case .here(let endpoint) = picture { endpoint } else { nil }
  }

  public var mirror: ScreenSharingViewerEndpoint? {
    if case .elsewhere(let endpoint) = picture { endpoint } else { nil }
  }
}
