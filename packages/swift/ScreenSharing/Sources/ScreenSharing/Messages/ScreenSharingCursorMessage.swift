import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The host's pointer as its own stream (851-2377), on the `codevisor.cursor.v1`
/// channel: the viewer draws it, so it moves as fast as the channel instead of
/// the video, and while controlling it's the local pointer itself. A viewer
/// that can draw it says so (`subscribe`); only then does the host take the
/// pointer out of the video and start sending it. A peer that predates the
/// channel never opens it and keeps the pointer in the video.
public enum ScreenSharingCursorMessage: Codable, Sendable, Equatable {
  /// Viewer → host: draw the pointer here, not into the video.
  case subscribe
  /// Host → viewer: the pointer's image.
  case shape(ScreenSharingCursorImage)
  /// Host → viewer: where the pointer is, normalized in the captured display
  /// (origin top left); nil while it's on another display or hidden.
  case position(ScreenSharingPointer?)

  /// A 2× cursor PNG with room to spare; the largest accessibility cursor sizes are sent at 1×.
  public static let maximumBytes = 32 * 1024

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = try encoder.encode(Envelope(version: 1, message: self))
    guard data.count <= Self.maximumBytes else { throw ScreenSharingError.invalid("Cursor message is too large.") }
    return data
  }

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw ScreenSharingError.invalid("Cursor message is too large.") }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1 else { throw ScreenSharingError.invalid("Unsupported cursor protocol.") }
    return envelope.message
  }

  private struct Envelope: Codable { let version: Int; let message: ScreenSharingCursorMessage }
}

/// A pointer image: a PNG at whatever pixel density the host has, its hotspot
/// in the PNG's pixels, and its size as a share of the captured display's, so
/// the viewer draws it in proportion to the video at any video resolution and
/// still sharp.
public struct ScreenSharingCursorImage: Codable, Sendable, Equatable {
  public var png: Data
  public var hotspotX: Int
  public var hotspotY: Int
  /// The image's width and height as fractions of the display's.
  public var width: Double
  public var height: Double

  public init(png: Data, hotspotX: Int, hotspotY: Int, width: Double, height: Double) {
    self.png = png; self.hotspotX = hotspotX; self.hotspotY = hotspotY; self.width = width; self.height = height
  }

  /// Encodes a pointer image drawn by `draw` into a `pixelWidth` × `pixelHeight` premultiplied context.
  public static func png(pixelWidth: Int, pixelHeight: Int, draw: (CGContext) -> Void) -> Data? {
    guard pixelWidth > 0, pixelHeight > 0,
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    draw(context)
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  /// The image as the viewer's cursor shape (premultiplied BGRA), or nil when the PNG
  /// doesn't decode, is larger than `RFBCursorShape.maximumDimension` or the hotspot is outside it.
  public func shape() -> RFBCursorShape? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let width = image.width, height = image.height
    guard (1...RFBCursorShape.maximumDimension).contains(width), (1...RFBCursorShape.maximumDimension).contains(height),
      (0..<width).contains(hotspotX), (0..<height).contains(hotspotY)
    else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    return RFBCursorShape(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY, pixels: pixels)
  }
}
