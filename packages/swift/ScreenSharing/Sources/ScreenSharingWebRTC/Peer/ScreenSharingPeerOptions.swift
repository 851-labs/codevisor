import Foundation
import ScreenSharing

public struct ScreenSharingPeerOptions: Sendable {
  public var codec: ScreenSharingVideoCodec = .hevc444
  public var fallbackCodecs: [ScreenSharingVideoCodec] = [.hevc, .h264]

  public init() {}
}
