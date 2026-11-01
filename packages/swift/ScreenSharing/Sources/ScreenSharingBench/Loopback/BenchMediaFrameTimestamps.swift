public struct BenchMediaFrameTimestamps: Codable, Sendable, Equatable {
  public var sendNs: Int64
  public var firstPacketOutNs: Int64?
  public var lastPacketOutNs: Int64?
  public var firstPacketInNs: Int64
  public var recovery: BenchMediaRecovery

  public init(
    sendNs: Int64, firstPacketOutNs: Int64?, lastPacketOutNs: Int64?, firstPacketInNs: Int64,
    recovery: BenchMediaRecovery
  ) {
    self.sendNs = sendNs
    self.firstPacketOutNs = firstPacketOutNs
    self.lastPacketOutNs = lastPacketOutNs
    self.firstPacketInNs = firstPacketInNs
    self.recovery = recovery
  }

  public func shifted(byNs offset: Int64) -> BenchMediaFrameTimestamps {
    BenchMediaFrameTimestamps(
      sendNs: sendNs + offset, firstPacketOutNs: firstPacketOutNs.map { $0 + offset },
      lastPacketOutNs: lastPacketOutNs.map { $0 + offset }, firstPacketInNs: firstPacketInNs + offset,
      recovery: recovery)
  }
}
