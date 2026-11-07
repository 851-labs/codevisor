public struct ScreenSharingTileNetworkFeedback: Sendable, Equatable {
  public let packetErrorRate: Double
  public let roundTripDelayMs: Double
  public let transmissionBitsPerSecond: Int
  public let transmissionMeasured: Bool

  public init(
    packetErrorRate: Double, roundTripDelayMs: Double, transmissionBitsPerSecond: Int, transmissionMeasured: Bool
  ) {
    self.packetErrorRate = packetErrorRate
    self.roundTripDelayMs = roundTripDelayMs
    self.transmissionBitsPerSecond = transmissionBitsPerSecond
    self.transmissionMeasured = transmissionMeasured
  }
}
