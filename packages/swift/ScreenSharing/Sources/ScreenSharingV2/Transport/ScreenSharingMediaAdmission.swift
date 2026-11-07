public struct ScreenSharingMediaAdmission: Equatable, Sendable {
  public let admit: Bool
  public let backlogBytes: UInt64
  public let estimateKbps: UInt64
  public let encoderCeilingKbps: UInt64
  public let measured: Bool

  public init(
    admit: Bool, backlogBytes: UInt64, estimateKbps: UInt64, encoderCeilingKbps: UInt64, measured: Bool = true
  ) {
    self.admit = admit
    self.backlogBytes = backlogBytes
    self.estimateKbps = estimateKbps
    self.measured = measured
    self.encoderCeilingKbps = encoderCeilingKbps
  }
}
