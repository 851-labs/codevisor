import CoreVideo

public struct BenchRGBImage: Sendable, Equatable {
  public static let channels = 3
  private static let bgraBytesPerPixel = 4

  public let width: Int
  public let height: Int
  public private(set) var pixels: [UInt8]

  public init(width: Int, height: Int, pixels: [UInt8]) {
    precondition(pixels.count == width * height * Self.channels, "An RGB image needs 3 bytes a pixel")
    self.width = width
    self.height = height
    self.pixels = pixels
  }

  public init(width: Int, height: Int, bgra: UnsafeRawBufferPointer, bytesPerRow: Int) {
    var pixels = [UInt8](repeating: 0, count: width * height * Self.channels)
    pixels.withUnsafeMutableBufferPointer { target in
      for y in 0..<height {
        for x in 0..<width {
          let source = y * bytesPerRow + x * Self.bgraBytesPerPixel
          let index = (y * width + x) * Self.channels
          target[index] = bgra[source + 2]
          target[index + 1] = bgra[source + 1]
          target[index + 2] = bgra[source]
        }
      }
    }
    self.init(width: width, height: height, pixels: pixels)
  }

  public init(bgraPixelBuffer buffer: CVPixelBuffer) throws {
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
      throw BenchBarcodeError.unsupportedPixelFormat(CVPixelBufferGetPixelFormatType(buffer))
    }

    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw BenchBarcodeError.pixelsUnavailable }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    self.init(
      width: CVPixelBufferGetWidth(buffer), height: height,
      bgra: UnsafeRawBufferPointer(start: base, count: bytesPerRow * height), bytesPerRow: bytesPerRow)
  }

  public func pixel(x: Int, y: Int) -> BenchRGB {
    let index = (y * width + x) * Self.channels
    return BenchRGB(red: pixels[index], green: pixels[index + 1], blue: pixels[index + 2])
  }

  public mutating func setPixel(x: Int, y: Int, _ color: BenchRGB) {
    let index = (y * width + x) * Self.channels
    pixels[index] = color.red
    pixels[index + 1] = color.green
    pixels[index + 2] = color.blue
  }

  public func cropped(to rect: BenchPixelRect) -> BenchRGBImage {
    precondition(rect.fits(width: width, height: height), "The crop must lie inside the image")
    var cropped = [UInt8]()
    cropped.reserveCapacity(rect.width * rect.height * Self.channels)
    for y in rect.y..<rect.maxY {
      let start = (y * width + rect.x) * Self.channels
      cropped.append(contentsOf: pixels[start..<start + rect.width * Self.channels])
    }
    return BenchRGBImage(width: rect.width, height: rect.height, pixels: cropped)
  }
}
