import CoreGraphics
import Foundation
import ImageIO

/// Tight (encoding 7), 851-2313, for the client's 24-bit-depth format: fill,
/// JPEG, and zlib "basic" rectangles with the copy, palette and gradient
/// filters over four persistent zlib streams. Tight's TPIXEL is three bytes
/// R, G, B (unlike ZRLE's CPIXEL, which follows the pixel format's byte
/// order); the framebuffer is B, G, R, X.
///
/// One decoder per connection: the zlib streams persist across rectangles
/// until the server resets them. Owned by the client's single read loop,
/// like `RFBInputStream`, which is why it is unchecked.
final class RFBTightDecoder: @unchecked Sendable {
  enum Filter: UInt8 { case copy = 0, palette = 1, gradient = 2 }

  /// The largest JPEG or compressed payload accepted for one rectangle.
  static let maximumPayload = 64 << 20
  private var streams: [RFBZlibInflater?] = [nil, nil, nil, nil]

  /// What the last rectangle was, for metrics and tests.
  private(set) var lastKind = ""

  func decode(_ rect: RFBRectangle, from stream: RFBInputStream, into framebuffer: RFBFramebuffer) async throws {
    try framebuffer.validate(rect)
    let control = try await stream.u8()
    for index in 0..<4 where control & (1 << index) != 0 { streams[index] = nil }
    let type = control >> 4
    switch type {
    case 8:  // fill
      let rgb = try await stream.bytes(3)
      lastKind = "fill"
      try framebuffer.fill(rect, blue: rgb[2], green: rgb[1], red: rgb[0])
    case 9:  // JPEG
      let length = try await Self.compactLength(from: stream)
      guard length <= Self.maximumPayload else { throw RFBError.malformed("Tight JPEG of \(length) bytes") }
      lastKind = "jpeg"
      try framebuffer.fillRaw(rect, from: try Self.decodeJPEG(try await stream.bytes(length), rect: rect))
    case 0...7:  // basic: bits 4–5 the stream, bit 6 an explicit filter
      let streamID = Int(type & 3)
      let filter: Filter
      if type & 4 != 0 {
        let id = try await stream.u8()
        guard let known = Filter(rawValue: id) else { throw RFBError.malformed("Tight filter \(id)") }
        filter = known
      } else {
        filter = .copy
      }
      lastKind = "\(filter)"
      let pixels: [UInt8]
      switch filter {
      case .copy:
        pixels = Self.bgra(fromRGB: try await data(rect.width * rect.height * 3, streamID: streamID, stream: stream))
      case .gradient:
        let residuals = try await data(rect.width * rect.height * 3, streamID: streamID, stream: stream)
        pixels = Self.bgra(fromRGB: Self.ungradient(residuals, width: rect.width, height: rect.height))
      case .palette:
        let count = Int(try await stream.u8()) + 1
        let palette = try await stream.bytes(count * 3)
        let rowBytes = count == 2 ? (rect.width + 7) / 8 : rect.width
        let indices = try await data(rowBytes * rect.height, streamID: streamID, stream: stream)
        pixels = try Self.bgra(indices: indices, palette: palette, count: count, width: rect.width, height: rect.height)
      }
      try framebuffer.fillRaw(rect, from: pixels)
    default:
      throw RFBError.malformed("Tight compression type \(type)")
    }
  }

  /// Payloads under 12 bytes are sent raw; larger ones as a compact length and zlib data.
  private func data(_ size: Int, streamID: Int, stream: RFBInputStream) async throws -> [UInt8] {
    guard size >= 12 else { return try await stream.bytes(size) }
    let length = try await Self.compactLength(from: stream)
    guard length <= Self.maximumPayload else { throw RFBError.malformed("Tight zlib data of \(length) bytes") }
    let compressed = try await stream.bytes(length)
    if streams[streamID] == nil { streams[streamID] = try RFBZlibInflater() }
    let inflated = try streams[streamID]!.inflate(compressed)
    guard inflated.count == size else {
      throw RFBError.malformed("Tight zlib data inflated to \(inflated.count) bytes, expected \(size)")
    }
    return inflated
  }

  /// 1–3 bytes, 7 bits each, least significant first; the high bit continues.
  static func compactLength(from stream: RFBInputStream) async throws -> Int {
    var length = 0
    for shift in [0, 7, 14] {
      let byte = try await stream.u8()
      length |= Int(shift == 14 ? byte : byte & 0x7F) << shift
      if shift == 14 || byte & 0x80 == 0 { break }
    }
    return length
  }

  static func bgra(fromRGB rgb: [UInt8]) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: rgb.count / 3 * 4)
    var target = 0
    for source in stride(from: 0, to: rgb.count, by: 3) {
      pixels[target] = rgb[source + 2]
      pixels[target + 1] = rgb[source + 1]
      pixels[target + 2] = rgb[source]
      target += 4
    }
    return pixels
  }

  /// The gradient filter: each component is its residual plus a prediction
  /// from the left, above and above-left pixels, clamped to 0…255.
  static func ungradient(_ residuals: [UInt8], width: Int, height: Int) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: residuals.count)
    for y in 0..<height {
      for x in 0..<width {
        for component in 0..<3 {
          let index = (y * width + x) * 3 + component
          let above = y > 0 ? Int(output[index - width * 3]) : 0
          let prediction: Int
          if x == 0 {
            prediction = above
          } else {
            let left = Int(output[index - 3])
            let aboveLeft = y > 0 ? Int(output[index - width * 3 - 3]) : 0
            prediction = min(max(left + above - aboveLeft, 0), 255)
          }
          output[index] = UInt8(truncatingIfNeeded: Int(residuals[index]) + prediction)
        }
      }
    }
    return output
  }

  static func bgra(indices: [UInt8], palette: [UInt8], count: Int, width: Int, height: Int) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    let rowBytes = count == 2 ? (width + 7) / 8 : width
    for y in 0..<height {
      for x in 0..<width {
        let index: Int
        if count == 2 {
          index = Int(indices[y * rowBytes + x / 8] >> (7 - UInt8(x % 8)) & 1)
        } else {
          index = Int(indices[y * rowBytes + x])
          guard index < count else { throw RFBError.malformed("Tight palette index \(index) of \(count)") }
        }
        let target = (y * width + x) * 4
        pixels[target] = palette[index * 3 + 2]
        pixels[target + 1] = palette[index * 3 + 1]
        pixels[target + 2] = palette[index * 3]
      }
    }
    return pixels
  }

  /// Decodes a JPEG into BGRA the rectangle's size.
  static func decodeJPEG(_ data: [UInt8], rect: RFBRectangle) throws -> [UInt8] {
    guard let source = CGImageSourceCreateWithData(Data(data) as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw RFBError.malformed("Tight JPEG didn't decode") }
    guard image.width == rect.width, image.height == rect.height else {
      throw RFBError.malformed(
        "Tight JPEG is \(image.width) × \(image.height) for a \(rect.width) × \(rect.height) rectangle")
    }
    var pixels = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: rect.width, height: rect.height, bitsPerComponent: 8,
          bytesPerRow: rect.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
      return true
    }
    guard drawn else { throw RFBError.malformed("Tight JPEG couldn't be drawn") }
    return pixels
  }
}
