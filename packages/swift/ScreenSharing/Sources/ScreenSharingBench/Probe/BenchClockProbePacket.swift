public struct BenchClockProbePacket: Sendable, Equatable {
  public enum Kind: UInt8, Sendable {
    case request = 1
    case reply = 2
  }

  public static let byteCount = 40
  private static let magic: [UInt8] = Array("CVCP".utf8)
  private static let protocolVersion: UInt8 = 1

  public let kind: Kind
  public let sequence: UInt64
  public let clientSendNs: Int64
  public let responderReceiveNs: Int64
  public let responderSendNs: Int64

  public static func request(sequence: UInt64, clientSendNs: Int64) -> BenchClockProbePacket {
    BenchClockProbePacket(
      kind: .request, sequence: sequence, clientSendNs: clientSendNs, responderReceiveNs: 0, responderSendNs: 0)
  }

  public init?(bytes: [UInt8]) {
    guard Self.hasHeader(bytes), let kind = Kind(rawValue: bytes[5]) else { return nil }

    self.init(
      kind: kind, sequence: Self.field(0, of: bytes), clientSendNs: Int64(bitPattern: Self.field(1, of: bytes)),
      responderReceiveNs: Int64(bitPattern: Self.field(2, of: bytes)),
      responderSendNs: Int64(bitPattern: Self.field(3, of: bytes)))
  }

  private init(kind: Kind, sequence: UInt64, clientSendNs: Int64, responderReceiveNs: Int64, responderSendNs: Int64) {
    self.kind = kind
    self.sequence = sequence
    self.clientSendNs = clientSendNs
    self.responderReceiveNs = responderReceiveNs
    self.responderSendNs = responderSendNs
  }

  public func reply(receivedNs: Int64, sentNs: Int64) -> BenchClockProbePacket {
    BenchClockProbePacket(
      kind: .reply, sequence: sequence, clientSendNs: clientSendNs, responderReceiveNs: receivedNs,
      responderSendNs: sentNs)
  }

  public func exchange(clientReceiveNs: Int64) -> BenchClockExchange {
    BenchClockExchange(
      localSendNs: clientSendNs, remoteReceiveNs: responderReceiveNs, remoteSendNs: responderSendNs,
      localReceiveNs: clientReceiveNs)
  }

  public var bytes: [UInt8] {
    let fields = [
      sequence, UInt64(bitPattern: clientSendNs), UInt64(bitPattern: responderReceiveNs),
      UInt64(bitPattern: responderSendNs),
    ]
    return Self.magic + [Self.protocolVersion, kind.rawValue, 0, 0] + fields.flatMap(Self.bigEndianBytes)
  }

  private static let headerByteCount = 8
  private static let fieldByteCount = 8

  private static func hasHeader(_ bytes: [UInt8]) -> Bool {
    bytes.count == byteCount && Array(bytes[0..<magic.count]) == magic && bytes[magic.count] == protocolVersion
  }

  private static func field(_ index: Int, of bytes: [UInt8]) -> UInt64 {
    let start = headerByteCount + index * fieldByteCount
    return bytes[start..<start + fieldByteCount].reduce(0) { $0 << 8 | UInt64($1) }
  }

  private static func bigEndianBytes(_ value: UInt64) -> [UInt8] {
    (0..<fieldByteCount).reversed().map { UInt8(truncatingIfNeeded: value >> (UInt64($0) * 8)) }
  }
}
