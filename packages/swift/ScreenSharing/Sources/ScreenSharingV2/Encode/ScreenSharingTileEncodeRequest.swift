import CoreVideo

public struct ScreenSharingTileEncodeRequest: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer
  public let sourceTimestampNs: Int64
  public let capturedNs: Int64
  public let refreshes: [Int: ScreenSharingTileRefresh]

  public init(
    pixelBuffer: CVPixelBuffer, sourceTimestampNs: Int64, capturedNs: Int64,
    refreshes: [Int: ScreenSharingTileRefresh] = [:]
  ) {
    self.pixelBuffer = pixelBuffer
    self.sourceTimestampNs = sourceTimestampNs
    self.capturedNs = capturedNs
    self.refreshes = refreshes
  }
}
