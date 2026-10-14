import Foundation

public enum ScreenSharingAudioMessage: Equatable, Sendable {
  case subscribe
  case unsubscribe
  case packet(ScreenSharingAudioPacket)

  public static let version: UInt8 = 1
  public static let maximumBytes = 4096

  public func encoded() -> Data {
    var data = Data([Self.version])
    switch self {
    case .subscribe: data.append(0)
    case .unsubscribe: data.append(1)
    case .packet(let packet):
      data.append(2)
      data.append(bigEndian: packet.sequence)
      data.append(bigEndian: UInt64(bitPattern: packet.timestampNs))
      data.append(bigEndian: packet.frames)
      data.append(packet.payload)
    }
    return data
  }

  public static func decode(_ data: Data) throws -> Self {
    let bytes = [UInt8](data)
    guard bytes.count >= 2, bytes.count <= maximumBytes else {
      throw ScreenSharingError.invalid("Audio message has the wrong size.")
    }
    guard bytes[0] == version else { throw ScreenSharingError.invalid("Unsupported audio protocol.") }
    switch bytes[1] {
    case 0 where bytes.count == 2: return .subscribe
    case 1 where bytes.count == 2: return .unsubscribe
    case 2 where bytes.count > 16:
      var reader = BigEndianReader(bytes: bytes, offset: 2)
      let sequence = reader.uint32()
      let timestamp = Int64(bitPattern: reader.uint64())
      let frames = reader.uint16()
      return .packet(
        ScreenSharingAudioPacket(
          sequence: sequence, timestampNs: timestamp, frames: frames, payload: Data(bytes[16...])))
    default: throw ScreenSharingError.invalid("Unknown audio message.")
    }
  }
}

public struct ScreenSharingAudioPacket: Equatable, Sendable {
  public var sequence: UInt32
  public var timestampNs: Int64
  public var frames: UInt16
  public var payload: Data

  public init(sequence: UInt32, timestampNs: Int64, frames: UInt16, payload: Data) {
    self.sequence = sequence; self.timestampNs = timestampNs; self.frames = frames; self.payload = payload
  }
}

extension Data {
  fileprivate mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}

private struct BigEndianReader {
  let bytes: [UInt8]
  var offset: Int

  mutating func uint16() -> UInt16 { UInt16(read(2)) }
  mutating func uint32() -> UInt32 { UInt32(read(4)) }
  mutating func uint64() -> UInt64 { read(8) }

  private mutating func read(_ count: Int) -> UInt64 {
    defer { offset += count }
    return bytes[offset..<offset + count].reduce(0) { $0 << 8 | UInt64($1) }
  }
}
