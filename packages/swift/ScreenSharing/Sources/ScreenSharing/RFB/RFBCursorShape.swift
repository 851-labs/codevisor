import Foundation

public struct RFBCursorShape: Sendable, Equatable {
  public static let maximumDimension = 256

  public var width: Int
  public var height: Int
  public var hotspotX: Int
  public var hotspotY: Int
  public var pixels: [UInt8]

  public var isHidden: Bool { width == 0 || height == 0 }
  public var isInvisible: Bool { isHidden || !stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] != 0 } }

  public init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, pixels: [UInt8]) {
    self.width = width
    self.height = height
    self.hotspotX = hotspotX
    self.hotspotY = hotspotY
    self.pixels = pixels
  }

  public static let hidden = RFBCursorShape(width: 0, height: 0, hotspotX: 0, hotspotY: 0, pixels: [])

  public static func maskLength(width: Int, height: Int) -> Int { (width + 7) / 8 * height }

  public static func decode(
    width: Int, height: Int, hotspotX: Int, hotspotY: Int, payload: [UInt8]
  ) throws -> RFBCursorShape {
    guard (0...maximumDimension).contains(width), (0...maximumDimension).contains(height) else {
      throw RFBError.malformed("cursor \(width) × \(height)")
    }
    guard width > 0, height > 0 else { return .hidden }
    let hotspotX = min(max(hotspotX, 0), width - 1)
    let hotspotY = min(max(hotspotY, 0), height - 1)
    let pixelBytes = width * height * 4
    guard payload.count == pixelBytes + maskLength(width: width, height: height) else {
      throw RFBError.malformed("cursor payload of \(payload.count) bytes for \(width) × \(height)")
    }
    let rowBytes = (width + 7) / 8
    var pixels = [UInt8](repeating: 0, count: pixelBytes)
    for y in 0..<height {
      for x in 0..<width where payload[pixelBytes + y * rowBytes + x / 8] & (0x80 >> UInt8(x % 8)) != 0 {
        let index = (y * width + x) * 4
        pixels[index] = payload[index]
        pixels[index + 1] = payload[index + 1]
        pixels[index + 2] = payload[index + 2]
        pixels[index + 3] = 255
      }
    }
    return RFBCursorShape(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY, pixels: pixels)
  }

  public func encodedPayload() -> [UInt8] {
    guard !isHidden else { return [] }
    let rowBytes = (width + 7) / 8
    var mask = [UInt8](repeating: 0, count: rowBytes * height)
    for y in 0..<height {
      for x in 0..<width where pixels[(y * width + x) * 4 + 3] != 0 {
        mask[y * rowBytes + x / 8] |= 0x80 >> UInt8(x % 8)
      }
    }
    return pixels + mask
  }
}
