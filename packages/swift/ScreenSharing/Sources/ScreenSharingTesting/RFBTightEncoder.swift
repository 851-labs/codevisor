import CoreGraphics
import Foundation
import ImageIO
import ScreenSharing
import UniformTypeIdentifiers

/// The reference server's Tight encoder (851-2313), choosing per rectangle
/// the way TigerVNC does: one colour → fill; up to 16 → palette (1-bit for
/// two colours) over zlib; more → JPEG when the client asked for a quality
/// level, else the copy filter over zlib. Four persistent zlib streams:
/// 0 copy, 1 two-colour palette, 2 indexed palette.
public final class RFBTightEncoder {
  public init() {}
  /// TigerVNC's JPEG quality for Tight quality levels 0…9.
  public static let jpegQuality = [15, 29, 41, 42, 62, 77, 79, 86, 92, 100]
  private var deflaters: [RFBZlibDeflater?] = [nil, nil, nil, nil]

  /// The bytes after the rectangle header.
  public func encode(_ rect: RFBRectangle, from framebuffer: RFBFramebuffer, qualityLevel: Int?) throws -> [UInt8] {
    // One preallocated pass (this encoder must not bound vnc-bench on large frames).
    let rgb = framebuffer.withPixels { pixels, stride in
      [UInt8](unsafeUninitializedCapacity: rect.width * rect.height * 3) { buffer, count in
        var target = 0
        for y in rect.y..<rect.maxY {
          var source = y * stride + rect.x * 4
          for _ in 0..<rect.width {
            buffer[target] = pixels[source + 2]
            buffer[target + 1] = pixels[source + 1]
            buffer[target + 2] = pixels[source]
            target += 3
            source += 4
          }
        }
        count = target
      }
    }
    var palette: [UInt32: UInt8] = [:]
    var order: [UInt32] = []
    for index in stride(from: 0, to: rgb.count, by: 3) where palette.count <= 16 {
      let colour = UInt32(rgb[index]) << 16 | UInt32(rgb[index + 1]) << 8 | UInt32(rgb[index + 2])
      if palette[colour] == nil {
        palette[colour] = UInt8(truncatingIfNeeded: order.count)
        order.append(colour)
      }
    }
    if order.count == 1 {
      return [0x80] + Array(rgb.prefix(3))
    }
    if order.count <= 16 {
      let two = order.count == 2
      let streamID = two ? 1 : 2
      var out: [UInt8] = [UInt8(streamID << 4) | 0x40, 1, UInt8(order.count - 1)]
      for colour in order { out += [UInt8(colour >> 16 & 0xFF), UInt8(colour >> 8 & 0xFF), UInt8(colour & 0xFF)] }
      let rowBytes = two ? (rect.width + 7) / 8 : rect.width
      var indices = [UInt8](repeating: 0, count: rowBytes * rect.height)
      for y in 0..<rect.height {
        for x in 0..<rect.width {
          let source = (y * rect.width + x) * 3
          let colour = UInt32(rgb[source]) << 16 | UInt32(rgb[source + 1]) << 8 | UInt32(rgb[source + 2])
          let index = palette[colour]!
          if two {
            indices[y * rowBytes + x / 8] |= index << (7 - UInt8(x % 8))
          } else {
            indices[y * rowBytes + x] = index
          }
        }
      }
      return out + (try compressed(indices, streamID: streamID))
    }
    if let qualityLevel {
      let jpeg = try Self.jpeg(rgb: rgb, width: rect.width, height: rect.height, quality: qualityLevel)
      return [0x90] + Self.compactLength(jpeg.count) + jpeg
    }
    var out: [UInt8] = [0x00]
    out.append(contentsOf: try compressed(rgb, streamID: 0))
    return out
  }

  private func compressed(_ data: [UInt8], streamID: Int) throws -> [UInt8] {
    guard data.count >= 12 else { return data }
    // zlib level 1: what TigerVNC uses at its default compression level, and fast enough not to bound the benchmark.
    if deflaters[streamID] == nil { deflaters[streamID] = try RFBZlibDeflater(level: 1) }
    let bytes = try deflaters[streamID]!.deflate(data)
    return Self.compactLength(bytes.count) + bytes
  }

  public static func compactLength(_ length: Int) -> [UInt8] {
    if length < 0x80 { return [UInt8(length)] }
    if length < 0x4000 { return [UInt8(length & 0x7F | 0x80), UInt8(length >> 7)] }
    return [UInt8(length & 0x7F | 0x80), UInt8(length >> 7 & 0x7F | 0x80), UInt8(length >> 14)]
  }

  static func jpeg(rgb: [UInt8], width: Int, height: Int, quality: Int) throws -> [UInt8] {
    var rgbx = [UInt8]()
    rgbx.reserveCapacity(width * height * 4)
    for index in stride(from: 0, to: rgb.count, by: 3) { rgbx += [rgb[index], rgb[index + 1], rgb[index + 2], 255] }
    guard let provider = CGDataProvider(data: Data(rgbx) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw RFBError.malformed("JPEG source image") }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw RFBError.malformed("JPEG destination")
    }
    let level = jpegQuality[min(max(quality, 0), 9)]
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: Double(level) / 100] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw RFBError.malformed("JPEG encoding") }
    return [UInt8](output as Data)
  }
}
