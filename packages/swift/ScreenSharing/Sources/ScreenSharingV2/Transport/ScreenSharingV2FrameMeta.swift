import Foundation

public struct ScreenSharingV2FrameMeta: Equatable, Sendable {
  public static let version: UInt8 = 2
  static let byteCount = 46
  private static let refreshFlag: UInt8 = 1
  private static let refinementFlag: UInt8 = 2

  public let sourceTimestampNs: Int64
  public let clock: UInt64
  public let captureUs: UInt32
  public let admissionUs: UInt32
  public let encodeUs: UInt32
  public let handOffUs: UInt32
  public let isRefresh: Bool
  public let update: ScreenSharingTileUpdate
  public let layout: ScreenSharingV2TileLayout

  public init(
    sourceTimestampNs: Int64, clock: UInt64, captureUs: UInt32, admissionUs: UInt32, encodeUs: UInt32,
    handOffUs: UInt32, isRefresh: Bool, update: ScreenSharingTileUpdate, layout: ScreenSharingV2TileLayout
  ) {
    self.sourceTimestampNs = sourceTimestampNs
    self.clock = clock
    self.captureUs = captureUs
    self.admissionUs = admissionUs
    self.encodeUs = encodeUs
    self.handOffUs = handOffUs
    self.isRefresh = isRefresh
    self.update = update
    self.layout = layout
  }

  public init(_ data: Data) throws {
    var reader = ScreenSharingV2ByteReader(data)
    guard data.count >= Self.byteCount, reader.byte() == Self.version else {
      throw ScreenSharingV2FrameMetaError.unsupported
    }

    let flags = reader.byte()
    let updateID = reader.integer(UInt32.self)
    let mask = reader.byte()
    let count = Int(reader.byte())
    let width = Int(reader.integer(UInt16.self))
    let height = Int(reader.integer(UInt16.self))
    let tileHeight = Int(reader.integer(UInt16.self))
    sourceTimestampNs = Int64(bitPattern: reader.integer(UInt64.self))
    clock = reader.integer(UInt64.self)
    captureUs = reader.integer(UInt32.self)
    admissionUs = reader.integer(UInt32.self)
    encodeUs = reader.integer(UInt32.self)
    handOffUs = reader.integer(UInt32.self)
    isRefresh = flags & Self.refreshFlag != 0
    guard (1...8).contains(count), width > 0, height > 0, tileHeight > 0 else {
      throw ScreenSharingV2FrameMetaError.unsupported
    }

    layout = ScreenSharingV2TileLayout(width: width, height: height, count: count, tileHeight: tileHeight)
    update = ScreenSharingTileUpdate(
      id: updateID, tiles: Set((0..<count).filter { mask & (1 << $0) != 0 }),
      isRefinement: flags & Self.refinementFlag != 0)
  }

  public var data: Data {
    var data = Data(capacity: Self.byteCount)
    data.append(Self.version)
    data.append((isRefresh ? Self.refreshFlag : 0) | (update.isRefinement ? Self.refinementFlag : 0))
    Self.append(update.id, to: &data)
    data.append(update.tiles.reduce(UInt8(0)) { $0 | (1 << UInt8($1)) })
    data.append(UInt8(layout.count))
    Self.append(UInt16(clamping: layout.width), to: &data)
    Self.append(UInt16(clamping: layout.height), to: &data)
    Self.append(UInt16(clamping: layout.tileHeight), to: &data)
    Self.append(UInt64(bitPattern: sourceTimestampNs), to: &data)
    Self.append(clock, to: &data)
    for value in [captureUs, admissionUs, encodeUs, handOffUs] { Self.append(value, to: &data) }
    return data
  }

  private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
    withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
  }
}
