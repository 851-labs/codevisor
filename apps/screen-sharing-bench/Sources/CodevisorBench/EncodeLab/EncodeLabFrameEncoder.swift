import CoreVideo

protocol EncodeLabFrameEncoder: AnyObject, Sendable {
  var outputs: [EncodeLabTileOutput] { get }

  func encode(_ inputs: [Int: CVPixelBuffer], frame: Int, tick: Int, refresh: EncodeLabRefresh?) throws
  func finish()
}
