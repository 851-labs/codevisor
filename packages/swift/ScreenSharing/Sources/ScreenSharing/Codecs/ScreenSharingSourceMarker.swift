import Foundation

enum ScreenSharingSourceMarker {
  static let identifier: [UInt8] = [
    0x9c, 0x2e, 0x7b, 0x41, 0xd5, 0x6a, 0x48, 0x1f, 0xb7, 0x93, 0x5e, 0xc4, 0x2d, 0x8a, 0x61, 0xf3,
  ]
  private static let userDataUnregistered: UInt8 = 5
  private static let valueByteCount = 10
  private static let payloadSize = identifier.count + valueByteCount
  private static let trailingBits: UInt8 = 0x80

  static func header(for codec: ScreenSharingVideoCodec) -> [UInt8] {
    codec == .h264 ? [0x06] : [0x4e, 0x01]
  }

  static func nalUnit(timestampNs: Int64, codec: ScreenSharingVideoCodec) -> Data {
    var unit = Data(header(for: codec))
    unit.append(userDataUnregistered)
    unit.append(UInt8(payloadSize))
    unit.append(contentsOf: identifier)
    let value = UInt64(bitPattern: timestampNs)
    for index in (0..<valueByteCount).reversed() {
      unit.append(0x80 | UInt8((value >> (7 * index)) & 0x7f))
    }
    unit.append(trailingBits)
    return unit
  }

  static func isMarker(_ unit: Data, codec: ScreenSharingVideoCodec) -> Bool {
    let header = header(for: codec)
    let identifierEnd = header.count + 2 + identifier.count
    guard unit.count >= identifierEnd else { return false }
    let bytes = [UInt8](unit.prefix(identifierEnd))
    return Array(bytes[0..<header.count]) == header && bytes[header.count] == userDataUnregistered
      && Array(bytes[(header.count + 2)..<identifierEnd]) == identifier
  }

  static func timestampNs(in units: [Data], codec: ScreenSharingVideoCodec) -> Int64? {
    let header = header(for: codec)
    let valueStart = header.count + 2 + identifier.count
    let expectedCount = valueStart + valueByteCount + 1
    for unit in units where unit.count == expectedCount && isMarker(unit, codec: codec) {
      let bytes = [UInt8](unit)
      guard bytes[header.count + 1] == UInt8(payloadSize), bytes[expectedCount - 1] == trailingBits,
        bytes[valueStart] == 0x80
      else { continue }
      var value: UInt64 = 0
      var valid = true
      for byte in bytes[(valueStart + 1)..<(valueStart + valueByteCount)] {
        guard byte & 0x80 != 0 else { valid = false; break }
        value = (value << 7) | UInt64(byte & 0x7f)
      }
      guard valid, value <= UInt64(Int64.max) else { continue }
      return Int64(value)
    }
    return nil
  }
}
