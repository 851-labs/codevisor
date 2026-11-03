public struct ScreenSharingVCPNetworkFeedback: Sendable, Equatable {
  public let packetErrorRate: Double
  public let roundTripDelayMs: Double
  public let transmissionBitsPerSecond: Int

  public init(packetErrorRate: Double, roundTripDelayMs: Double, transmissionBitsPerSecond: Int) {
    self.packetErrorRate = packetErrorRate
    self.roundTripDelayMs = roundTripDelayMs
    self.transmissionBitsPerSecond = transmissionBitsPerSecond
  }
}
