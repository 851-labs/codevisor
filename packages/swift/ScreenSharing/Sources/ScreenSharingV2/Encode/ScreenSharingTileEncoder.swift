import CoreVideo

public protocol ScreenSharingTileEncoder: AnyObject, Sendable {
  var layout: ScreenSharingV2TileLayout { get }
  var sourcePixelFormat: OSType { get }
  var refinementPolicy: ScreenSharingV2RefinementPolicy { get }
  func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void)
  func encode(_ request: ScreenSharingTileEncodeRequest) throws
  func acknowledge(_ tokens: [UInt64], tile: Int)
  func observeNetwork(_ feedback: ScreenSharingTileNetworkFeedback)
  func setBitrate(_ bitsPerSecond: Int) throws
  func suspend()
  func resume() throws
  func stop()
}

extension ScreenSharingTileEncoder {
  public func observeNetwork(_ feedback: ScreenSharingTileNetworkFeedback) {}

  public func suspend() {}
  public func resume() throws {}
}

extension ScreenSharingTileEncoder {
  public var refinementPolicy: ScreenSharingV2RefinementPolicy { .standard }
}
