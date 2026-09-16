import Foundation

/// ZRLE (RFC 6143 §7.7.6) for the client's 24-bit-depth format, where each
/// CPIXEL is three bytes: B, G, R in our little-endian layout.
package enum RFBZRLEDecoder {
  package static let tile = 64

  static func decode(_ data: [UInt8], rect: RFBRectangle, into framebuffer: RFBFramebuffer) throws {
    try framebuffer.validate(rect)
    var cursor = Cursor(data: data)
    try framebuffer.withMutablePixels { base, stride in
      var tileY = rect.y
      while tileY < rect.maxY {
        let tileHeight = min(tile, rect.maxY - tileY)
        var tileX = rect.x
        while tileX < rect.maxX {
          let tileWidth = min(tile, rect.maxX - tileX)
          let origin = base + tileY * stride + tileX * 4
          try decodeTile(&cursor, width: tileWidth, height: tileHeight, origin: origin, stride: stride)
          tileX += tile
        }
        tileY += tile
      }
    }
    guard cursor.atEnd else { throw RFBError.malformed("ZRLE trailing bytes") }
  }

  private static func decodeTile(
    _ cursor: inout Cursor, width: Int, height: Int, origin: UnsafeMutablePointer<UInt8>, stride: Int
  ) throws {
    let subencoding = try cursor.u8()
    @inline(__always) func store(_ pixel: (UInt8, UInt8, UInt8), at index: Int) {
      let pointer = origin + (index / width) * stride + (index % width) * 4
      pointer[0] = pixel.0; pointer[1] = pixel.1; pointer[2] = pixel.2; pointer[3] = 0xff
    }
    let count = width * height
    switch subencoding {
    case 0:
      for index in 0..<count { store(try cursor.cpixel(), at: index) }
    case 1:
      let pixel = try cursor.cpixel()
      for index in 0..<count { store(pixel, at: index) }
    case 2...16:
      let palette = try (0..<Int(subencoding)).map { _ in try cursor.cpixel() }
      let bits = subencoding == 2 ? 1 : (subencoding <= 4 ? 2 : 4)
      let mask = UInt8((1 << bits) - 1)
      for row in 0..<height {
        var byte: UInt8 = 0
        var remaining = 0
        for column in 0..<width {
          if remaining == 0 { byte = try cursor.u8(); remaining = 8 }
          remaining -= bits
          let index = Int((byte >> UInt8(remaining)) & mask)
          guard index < palette.count else { throw RFBError.malformed("ZRLE palette index") }
          store(palette[index], at: row * width + column)
        }
      }
    case 128:
      var index = 0
      while index < count {
        let pixel = try cursor.cpixel()
        let length = try cursor.runLength()
        guard index + length <= count else { throw RFBError.malformed("ZRLE run overflow") }
        for _ in 0..<length { store(pixel, at: index); index += 1 }
      }
    case 130...255:
      let palette = try (0..<Int(subencoding - 128)).map { _ in try cursor.cpixel() }
      var index = 0
      while index < count {
        let byte = try cursor.u8()
        let paletteIndex = Int(byte & 127)
        guard paletteIndex < palette.count else { throw RFBError.malformed("ZRLE palette index") }
        let length = byte & 128 != 0 ? try cursor.runLength() : 1
        guard index + length <= count else { throw RFBError.malformed("ZRLE run overflow") }
        for _ in 0..<length { store(palette[paletteIndex], at: index); index += 1 }
      }
    default:
      throw RFBError.malformed("ZRLE subencoding \(subencoding)")
    }
  }

  struct Cursor {
    let data: [UInt8]
    var offset = 0
    var atEnd: Bool { offset == data.count }

    mutating func u8() throws -> UInt8 {
      guard offset < data.count else { throw RFBError.malformed("ZRLE truncated") }
      defer { offset += 1 }
      return data[offset]
    }

    mutating func cpixel() throws -> (UInt8, UInt8, UInt8) {
      guard offset + 3 <= data.count else { throw RFBError.malformed("ZRLE truncated") }
      defer { offset += 3 }
      return (data[offset], data[offset + 1], data[offset + 2])
    }

    /// Run lengths are 1 plus a sum of bytes, each 255 adding another byte.
    mutating func runLength() throws -> Int {
      var length = 1
      while true {
        let byte = try u8()
        length += Int(byte)
        if byte < 255 { return length }
      }
    }
  }
}
