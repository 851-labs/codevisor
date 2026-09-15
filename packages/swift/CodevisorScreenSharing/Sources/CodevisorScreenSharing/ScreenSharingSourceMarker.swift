import Foundation

/// Every encoded frame carries its content identity (the capture timestamp)
/// in a user-data SEI NAL unit, so the viewer can confirm that it decoded the
/// host's newest picture. WebRTC's RTP timestamps gain a random per-session
/// offset and frame counts diverge whenever the viewer's jitter buffer drops a
/// late frame; the marker is exact. Its bytes never include zero, so no
/// start-code emulation can occur, and the decoder strips it before
/// VideoToolbox sees the frame.
enum ScreenSharingSourceMarker {
  /// uuid_iso_iec_11578 identifying Codevisor frame markers; no zero bytes.
  static let identifier: [UInt8] = [
    0x9c, 0x2e, 0x7b, 0x41, 0xd5, 0x6a, 0x48, 0x1f, 0xb7, 0x93, 0x5e, 0xc4, 0x2d, 0x8a, 0x61, 0xf3,
  ]
  private static let userDataUnregistered: UInt8 = 5
  /// Seven payload bits per byte with the high bit set: 70 bits, never zero.
  /// The leading group is always 0x80 for a canonical non-negative value.
  private static let valueByteCount = 10
  private static let payloadSize = identifier.count + valueByteCount
  private static let trailingBits: UInt8 = 0x80

  /// H.264 SEI (nal_ref_idc 0, type 6); HEVC prefix SEI (type 39, layer 0, TID 1).
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

  /// A Codevisor marker of any length, so malformed markers are still stripped.
  static func isMarker(_ unit: Data, codec: ScreenSharingVideoCodec) -> Bool {
    let header = header(for: codec)
    let identifierEnd = header.count + 2 + identifier.count
    guard unit.count >= identifierEnd else { return false }
    let bytes = [UInt8](unit.prefix(identifierEnd))
    return Array(bytes[0..<header.count]) == header && bytes[header.count] == userDataUnregistered
      && Array(bytes[(header.count + 2)..<identifierEnd]) == identifier
  }

  /// The marker's identity, or nil when absent or malformed. Foreign SEI
  /// units of any other layout are ignored, never misread.
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
