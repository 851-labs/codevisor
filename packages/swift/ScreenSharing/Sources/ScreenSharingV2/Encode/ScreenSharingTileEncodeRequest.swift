import CoreVideo

public struct ScreenSharingTileEncodeRequest: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer
  public let sourceTimestampNs: Int64
  public let capturedNs: Int64
  public let update: ScreenSharingTileUpdate
  public private(set) var refreshes: [Int: ScreenSharingTileRefresh]
  public let smallTiles: Set<Int>
  public let repeatedTiles: Set<Int>
  public let contentIntervalsNs: [Int: Int64]

  public init(
    pixelBuffer: CVPixelBuffer, sourceTimestampNs: Int64, capturedNs: Int64, update: ScreenSharingTileUpdate,
    refreshes: [Int: ScreenSharingTileRefresh] = [:], smallTiles: Set<Int> = [], repeatedTiles: Set<Int> = [],
    contentIntervalsNs: [Int: Int64] = [:]
  ) {
    self.pixelBuffer = pixelBuffer
    self.sourceTimestampNs = sourceTimestampNs
    self.capturedNs = capturedNs
    self.update = update
    self.refreshes = refreshes
    self.smallTiles = smallTiles
    self.repeatedTiles = repeatedTiles
    self.contentIntervalsNs = contentIntervalsNs.filter { !repeatedTiles.contains($0.key) }
  }

  public func refreshing(_ tiles: Set<Int>, with refresh: ScreenSharingTileRefresh) -> ScreenSharingTileEncodeRequest {
    var copy = self
    for tile in tiles { copy.refreshes[tile] = refresh }
    return copy
  }
}
