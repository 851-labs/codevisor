import Foundation

struct ScreenSharingV2ByteReader {
  private let bytes: [UInt8]
  private var offset = 0

  init(_ data: Data) {
    bytes = [UInt8](data)
  }

  mutating func byte() -> UInt8 {
    integer(UInt8.self)
  }

  mutating func integer<Value: FixedWidthInteger>(_ type: Value.Type) -> Value {
    let size = MemoryLayout<Value>.size
    guard offset + size <= bytes.count else { return 0 }

    defer { offset += size }
    return bytes[offset..<(offset + size)].reduce(Value.zero) { ($0 << 8) | Value($1) }
  }
}
