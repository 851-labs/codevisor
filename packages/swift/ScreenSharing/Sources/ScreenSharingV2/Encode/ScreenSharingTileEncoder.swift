import CoreVideo

public protocol ScreenSharingTileEncoder: AnyObject, Sendable {
  var layout: ScreenSharingV2TileLayout { get }
  var sourcePixelFormat: OSType { get }
  func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void)
  func encode(_ request: ScreenSharingTileEncodeRequest) throws
  func acknowledge(_ tokens: [UInt64], tile: Int)
  func setBitrate(_ bitsPerSecond: Int) throws
  func stop()
}
