public struct BenchRtpHeader: Sendable, Equatable {
  private static let headerBytes = 12
  private static let version: UInt8 = 2
  private static let paddingBit: UInt8 = 0x20
  private static let rtcpPacketTypes: ClosedRange<UInt8> = 64...95

  public let timestamp: UInt32
  public let hasPadding: Bool

  public init?(_ bytes: [UInt8]) {
    guard bytes.count >= Self.headerBytes, bytes[0] >> 6 == Self.version else { return nil }
    guard !Self.rtcpPacketTypes.contains(bytes[1] & 0x7F) else { return nil }

    timestamp = bytes[4..<8].reduce(0) { $0 << 8 | UInt32($1) }
    hasPadding = bytes[0] & Self.paddingBit != 0
  }
}
