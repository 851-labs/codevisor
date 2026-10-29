public struct BenchVersionMessage: Sendable, Equatable {
  public static let byteCount = 20
  private static let magic: [UInt8] = Array("CVFV".utf8)
  private static let protocolVersion: UInt8 = 1
  private static let headerByteCount = 8
  private static let versionByteCount = 4
  private static let timeByteCount = 8

  public let version: Int
  public let hostOnGlassNs: Int64

  public init(version: Int, hostOnGlassNs: Int64) {
    self.version = version
    self.hostOnGlassNs = hostOnGlassNs
  }

  public init?(bytes: [UInt8]) {
    guard Self.hasHeader(bytes) else { return nil }

    version = Int(Self.integer(bytes, from: Self.headerByteCount, count: Self.versionByteCount))
    hostOnGlassNs = Int64(
      bitPattern: Self.integer(bytes, from: Self.headerByteCount + Self.versionByteCount, count: Self.timeByteCount))
  }

  public var bytes: [UInt8] {
    Self.magic + [Self.protocolVersion, 0, 0, 0] + Self.bigEndian(UInt64(version), count: Self.versionByteCount)
      + Self.bigEndian(UInt64(bitPattern: hostOnGlassNs), count: Self.timeByteCount)
  }

  private static func hasHeader(_ bytes: [UInt8]) -> Bool {
    bytes.count == byteCount && Array(bytes[0..<magic.count]) == magic && bytes[magic.count] == protocolVersion
  }

  private static func integer(_ bytes: [UInt8], from start: Int, count: Int) -> UInt64 {
    bytes[start..<start + count].reduce(0) { $0 << 8 | UInt64($1) }
  }

  private static func bigEndian(_ value: UInt64, count: Int) -> [UInt8] {
    (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (UInt64($0) * 8)) }
  }
}
