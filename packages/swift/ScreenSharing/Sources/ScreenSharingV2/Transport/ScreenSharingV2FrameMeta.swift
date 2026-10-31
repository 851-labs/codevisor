import Foundation

public struct ScreenSharingV2FrameMeta: Equatable, Sendable {
  public static let version: UInt8 = 1
  static let byteCount = 34
  private static let refreshFlag: UInt8 = 1

  public let sourceTimestampNs: Int64
  public let clock: UInt64
  public let captureUs: UInt32
  public let admissionUs: UInt32
  public let encodeUs: UInt32
  public let handOffUs: UInt32
  public let isRefresh: Bool

  public init(
    sourceTimestampNs: Int64, clock: UInt64, captureUs: UInt32, admissionUs: UInt32, encodeUs: UInt32,
    handOffUs: UInt32, isRefresh: Bool
  ) {
    self.sourceTimestampNs = sourceTimestampNs
    self.clock = clock
    self.captureUs = captureUs
    self.admissionUs = admissionUs
    self.encodeUs = encodeUs
    self.handOffUs = handOffUs
    self.isRefresh = isRefresh
  }

  public init(_ data: Data) throws {
    var reader = ScreenSharingV2ByteReader(data)
    guard data.count >= Self.byteCount, reader.byte() == Self.version else {
      throw ScreenSharingV2FrameMetaError.unsupported
    }

    let flags = reader.byte()
    sourceTimestampNs = Int64(bitPattern: reader.integer(UInt64.self))
    clock = reader.integer(UInt64.self)
    captureUs = reader.integer(UInt32.self)
    admissionUs = reader.integer(UInt32.self)
    encodeUs = reader.integer(UInt32.self)
    handOffUs = reader.integer(UInt32.self)
    isRefresh = flags & Self.refreshFlag != 0
  }

  public var data: Data {
    var data = Data(capacity: Self.byteCount)
    data.append(Self.version)
    data.append(isRefresh ? Self.refreshFlag : 0)
    Self.append(UInt64(bitPattern: sourceTimestampNs), to: &data)
    Self.append(clock, to: &data)
    for value in [captureUs, admissionUs, encodeUs, handOffUs] { Self.append(value, to: &data) }
    return data
  }

  private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
    withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
  }
}
