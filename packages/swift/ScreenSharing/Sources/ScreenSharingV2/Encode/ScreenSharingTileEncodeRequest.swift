import CoreVideo

public struct ScreenSharingTileEncodeRequest: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer
  public let sourceTimestampNs: Int64
  public let capturedNs: Int64
  public let update: ScreenSharingTileUpdate
  public let refreshes: [Int: ScreenSharingTileRefresh]
  public let smallTiles: Set<Int>
  public let repeatedTiles: Set<Int>

  public init(
    pixelBuffer: CVPixelBuffer, sourceTimestampNs: Int64, capturedNs: Int64, update: ScreenSharingTileUpdate,
    refreshes: [Int: ScreenSharingTileRefresh] = [:], smallTiles: Set<Int> = [], repeatedTiles: Set<Int> = []
  ) {
    self.pixelBuffer = pixelBuffer
    self.sourceTimestampNs = sourceTimestampNs
    self.capturedNs = capturedNs
    self.update = update
    self.refreshes = refreshes
    self.smallTiles = smallTiles
    self.repeatedTiles = repeatedTiles
  }
}
