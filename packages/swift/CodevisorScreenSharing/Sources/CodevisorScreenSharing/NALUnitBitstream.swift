import Foundation

/// WebRTC uses Annex B; VideoToolbox uses big-endian length-prefixed NALs.
/// Keep framing validation independent of the hardware codec.
enum NALUnitBitstream {
  static let maximumFrameBytes = 16 * 1024 * 1024

  static func nalUnits(_ annexB: Data) throws -> [Data] {
    guard !annexB.isEmpty, annexB.count <= maximumFrameBytes else {
      throw ScreenSharingError.invalid("Invalid NAL frame size.")
    }
    let bytes = [UInt8](annexB)
    var starts: [(offset: Int, size: Int)] = []
    var index = 0
    while index + 2 < bytes.count {
      if bytes[index] == 0, bytes[index + 1] == 0 {
        if bytes[index + 2] == 1 {
          guard starts.count < 1024 else { throw ScreenSharingError.invalid("Too many NAL units.") }
          starts.append((index, 3)); index += 3; continue
        }
        if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
          guard starts.count < 1024 else { throw ScreenSharingError.invalid("Too many NAL units.") }
          starts.append((index, 4)); index += 4; continue
        }
      }
      index += 1
    }
    guard let first = starts.first, first.offset == 0 else {
      throw ScreenSharingError.invalid("NAL frame has no Annex B prefix.")
    }
    return try starts.enumerated().map { position, start in
      let begin = start.offset + start.size
      let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
      guard begin < end else { throw ScreenSharingError.invalid("Empty NAL unit.") }
      return Data(bytes[begin..<end])
    }
  }

  static func lengthPrefixed(_ units: [Data]) throws -> Data {
    var result = Data()
    for unit in units {
      guard !unit.isEmpty, unit.count <= maximumFrameBytes - result.count - 4 else {
        throw ScreenSharingError.invalid("Invalid NAL unit size.")
      }
      var length = UInt32(unit.count).bigEndian
      withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
      result.append(unit)
    }
    return result
  }

  static func annexB(_ avcc: Data, lengthSize: Int = 4) throws -> Data {
    guard !avcc.isEmpty, (1...4).contains(lengthSize), avcc.count <= maximumFrameBytes else {
      throw ScreenSharingError.invalid("Invalid NAL length field.")
    }
    let bytes = [UInt8](avcc)
    var result = Data()
    var offset = 0
    while offset < bytes.count {
      guard bytes.count - offset >= lengthSize else { throw ScreenSharingError.invalid("Truncated NAL length.") }
      var length = 0
      for byte in bytes[offset..<(offset + lengthSize)] { length = (length << 8) | Int(byte) }
      offset += lengthSize
      guard length > 0, length <= bytes.count - offset,
        length <= maximumFrameBytes - result.count - 4
      else { throw ScreenSharingError.invalid("Truncated NAL unit.") }
      result.append(contentsOf: [0, 0, 0, 1])
      result.append(contentsOf: bytes[offset..<(offset + length)])
      offset += length
    }
    return result
  }
}
