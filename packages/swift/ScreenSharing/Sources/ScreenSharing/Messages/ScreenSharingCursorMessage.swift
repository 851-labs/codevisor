import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenSharingCursorMessage: Codable, Sendable, Equatable {
  case subscribe
  case shape(ScreenSharingCursorImage)
  case position(ScreenSharingPointer?)

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

public struct ScreenSharingCursorImage: Codable, Sendable, Equatable {
  public var png: Data
  public var hotspotX: Int
  public var hotspotY: Int
  public var width: Double
  public var height: Double

  public init(png: Data, hotspotX: Int, hotspotY: Int, width: Double, height: Double) {
    self.png = png; self.hotspotX = hotspotX; self.hotspotY = hotspotY; self.width = width; self.height = height
  }

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
