import Foundation

/// The client's copy of the remote screen, in `RFBPixelFormat.bgra32`. Written
/// only by the client's read loop; the update callback may read it for the
/// duration of the call, after which the next update may write again.
public final class RFBFramebuffer: @unchecked Sendable {
  public static let maximumDimension = 16384
  public private(set) var width: Int
  public private(set) var height: Int
  public private(set) var pixels: [UInt8]
  public var bytesPerRow: Int { width * 4 }

  public init(width: Int, height: Int) throws {
    guard (1...Self.maximumDimension).contains(width), (1...Self.maximumDimension).contains(height) else {
      throw RFBError.malformed("framebuffer \(width) × \(height)")
    }
    self.width = width
    self.height = height
    pixels = [UInt8](repeating: 0, count: width * height * 4)
  }

  /// DesktopSize: the content is undefined until the server repaints it.
  public func resize(width: Int, height: Int) throws {
    guard (1...Self.maximumDimension).contains(width), (1...Self.maximumDimension).contains(height) else {
      throw RFBError.malformed("framebuffer \(width) × \(height)")
    }
    self.width = width
    self.height = height
    pixels = [UInt8](repeating: 0, count: width * height * 4)
  }

  public func contains(_ rect: RFBRectangle) -> Bool {
    rect.x >= 0 && rect.y >= 0 && rect.width >= 0 && rect.height >= 0 && rect.maxX <= width && rect.maxY <= height
  }

  func validate(_ rect: RFBRectangle) throws {
    guard contains(rect) else { throw RFBError.malformed("rectangle \(rect) outside \(width) × \(height)") }
  }

  /// Raw encoding: `bytes` holds `rect.width * rect.height` BGRA pixels, row-major.
  public func fillRaw(_ rect: RFBRectangle, from bytes: [UInt8]) throws {
    try validate(rect)
    guard bytes.count == rect.width * rect.height * 4 else { throw RFBError.malformed("raw rectangle size") }
    let rowBytes = rect.width * 4
    let stride = bytesPerRow
    pixels.withUnsafeMutableBufferPointer { destination in
      bytes.withUnsafeBufferPointer { source in
        for row in 0..<rect.height {
          let target = destination.baseAddress! + (rect.y + row) * stride + rect.x * 4
          target.update(from: source.baseAddress! + row * rowBytes, count: rowBytes)
        }
      }
    }
  }

  /// CopyRect: the source and destination may overlap.
  public func copy(_ rect: RFBRectangle, fromX: Int, fromY: Int) throws {
    try validate(rect)
    try validate(RFBRectangle(x: fromX, y: fromY, width: rect.width, height: rect.height))
    guard !rect.isEmpty else { return }
    let rowBytes = rect.width * 4
    let stride = bytesPerRow
    pixels.withUnsafeMutableBufferPointer { buffer in
      let base = buffer.baseAddress!
      let rows = fromY < rect.y ? Array((0..<rect.height).reversed()) : Array(0..<rect.height)
      for row in rows {
        memmove(base + (rect.y + row) * stride + rect.x * 4, base + (fromY + row) * stride + fromX * 4, rowBytes)
      }
    }
  }

  public func fill(_ rect: RFBRectangle, blue: UInt8, green: UInt8, red: UInt8) throws {
    try validate(rect)
    let stride = bytesPerRow
    pixels.withUnsafeMutableBufferPointer { buffer in
      let base = buffer.baseAddress!
      for row in 0..<rect.height {
        var pointer = base + (rect.y + row) * stride + rect.x * 4
        for _ in 0..<rect.width {
          pointer[0] = blue; pointer[1] = green; pointer[2] = red; pointer[3] = 0xff
          pointer += 4
        }
      }
    }
  }

  /// One pixel as (blue, green, red); tests and cursor logic.
  public func pixel(x: Int, y: Int) -> (blue: UInt8, green: UInt8, red: UInt8) {
    let index = (y * width + x) * 4
    return (pixels[index], pixels[index + 1], pixels[index + 2])
  }

  /// Direct access for decoders: `body` receives the base pointer and the row stride in bytes.
  func withMutablePixels<T>(_ body: (UnsafeMutablePointer<UInt8>, Int) throws -> T) rethrows -> T {
    let stride = bytesPerRow
    return try pixels.withUnsafeMutableBufferPointer { try body($0.baseAddress!, stride) }
  }

  /// Read access for consumers copying rows out (the pixel-buffer bridge).
  public func withPixels<T>(_ body: (UnsafeBufferPointer<UInt8>, _ bytesPerRow: Int) throws -> T) rethrows -> T {
    let stride = bytesPerRow
    return try pixels.withUnsafeBufferPointer { try body($0, stride) }
  }
}
