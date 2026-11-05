import CoreVideo
import ScreenSharing

public protocol ScreenSharingTileEncoder: AnyObject, Sendable {
  var layout: ScreenSharingV2TileLayout { get }
  var sourcePixelFormat: OSType { get }
  var refinementPolicy: ScreenSharingV2RefinementPolicy { get }
  func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void)
  func prepare(_ frame: ScreenSharingVideoFrame, tiles: Set<Int>)
  func encode(_ request: ScreenSharingTileEncodeRequest) throws
  func acknowledge(_ tokens: [UInt64], tile: Int)
  func observeNetwork(_ feedback: ScreenSharingTileNetworkFeedback)
  func setBitrate(_ bitsPerSecond: Int) throws
  func stop()
}

extension ScreenSharingTileEncoder {
  public func prepare(_ frame: ScreenSharingVideoFrame, tiles: Set<Int>) {}
  public func observeNetwork(_ feedback: ScreenSharingTileNetworkFeedback) {}
}

extension ScreenSharingTileEncoder {
  public var refinementPolicy: ScreenSharingV2RefinementPolicy { .standard }
}
