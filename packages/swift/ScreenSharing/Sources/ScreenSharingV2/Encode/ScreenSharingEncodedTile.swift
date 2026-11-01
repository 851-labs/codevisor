public struct ScreenSharingEncodedTile: Sendable {
  public let tile: Int
  public let sourceTimestampNs: Int64
  public let capturedNs: Int64
  public let submittedNs: Int64
  public let encodedNs: Int64
  public let isKeyFrame: Bool
  public let refresh: ScreenSharingTileRefresh?
  public let ltrToken: UInt64?
  public let accessUnit: ScreenSharingAccessUnit

  public init(
    tile: Int, sourceTimestampNs: Int64, capturedNs: Int64, submittedNs: Int64, encodedNs: Int64, isKeyFrame: Bool,
    refresh: ScreenSharingTileRefresh?, ltrToken: UInt64?, accessUnit: ScreenSharingAccessUnit
  ) {
    self.tile = tile
    self.sourceTimestampNs = sourceTimestampNs
    self.capturedNs = capturedNs
    self.submittedNs = submittedNs
    self.encodedNs = encodedNs
    self.isKeyFrame = isKeyFrame
    self.refresh = refresh
    self.ltrToken = ltrToken
    self.accessUnit = accessUnit
  }

  public var recovers: Bool { isKeyFrame || refresh != nil }
}
