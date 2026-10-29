import Foundation
import ScreenSharing

public struct ScreenSharingPeerOptions: Sendable {
  public var codec = ScreenSharingProductProfile.codec
  public var fallbackCodecs = ScreenSharingProductProfile.fallbackCodecs
  var fieldTrials: ScreenSharingFieldTrials = .process

  public init() {}
}
