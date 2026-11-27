public struct ScreenSharingEncodedTile: Sendable {
  public let tile: Int
  public let update: ScreenSharingTileUpdate
  public let sourceTimestampNs: Int64
  public let capturedNs: Int64
  public let submittedNs: Int64
  public let encodedNs: Int64
  public let isKeyFrame: Bool
  public let refresh: ScreenSharingTileRefresh?
  public let ltrToken: UInt64?
  public let accessUnit: ScreenSharingAccessUnit
  public let repeatsCapture: Bool

  public init(
    tile: Int, update: ScreenSharingTileUpdate, sourceTimestampNs: Int64, capturedNs: Int64, submittedNs: Int64,
    encodedNs: Int64, isKeyFrame: Bool, refresh: ScreenSharingTileRefresh?, ltrToken: UInt64?,
    accessUnit: ScreenSharingAccessUnit, repeatsCapture: Bool = false
  ) {
    self.tile = tile
    self.update = update
    self.sourceTimestampNs = sourceTimestampNs
    self.capturedNs = capturedNs
    self.submittedNs = submittedNs
    self.encodedNs = encodedNs
    self.isKeyFrame = isKeyFrame
    self.refresh = refresh
    self.ltrToken = ltrToken
    self.accessUnit = accessUnit
    self.repeatsCapture = repeatsCapture
  }

  public var recovers: Bool { isKeyFrame || refresh != nil }

  func withToken(_ token: UInt64?) -> ScreenSharingEncodedTile {
    ScreenSharingEncodedTile(
      tile: tile, update: update, sourceTimestampNs: sourceTimestampNs, capturedNs: capturedNs,
      submittedNs: submittedNs, encodedNs: encodedNs, isKeyFrame: isKeyFrame, refresh: refresh, ltrToken: token,
      accessUnit: accessUnit, repeatsCapture: repeatsCapture)
  }
}
