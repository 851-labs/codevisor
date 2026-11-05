import CoreVideo
import ScreenSharingBench

enum VCPLevelsRamp {
  typealias Colour = (red: UInt8, green: UInt8, blue: UInt8)

  static let patch = 32
  private static let columns = 32
  static let width = columns * patch
  static let colours: [Colour] =
    (0...255).map { (UInt8($0), UInt8($0), UInt8($0)) } + [
      (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (0, 255, 255), (255, 0, 255), (89, 25, 128),
      (25, 51, 204), (230, 25, 25), (25, 179, 51), (204, 25, 179), (128, 64, 32), (32, 64, 128), (200, 150, 100),
      (100, 150, 200), (64, 128, 64), (180, 40, 90), (16, 16, 32), (40, 32, 24),
    ]
  static let height = (colours.count + columns - 1) / columns * patch

  static func bgra() throws -> CVPixelBuffer {
    let buffer = try make(kCVPixelFormatType_32BGRA)
    try fill(buffer, plane: nil) { colour in [colour.blue, colour.green, colour.red, 255] }
    return buffer
  }

  static func fullRange444(tagged: Bool) throws -> CVPixelBuffer {
    let buffer = try make(kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)
    try fill(buffer, plane: 0) { [UInt8(VCPLevelsExpectation.fullRange.values($0)[0])] }
    try fill(buffer, plane: 1) { VCPLevelsExpectation.fullRange.values($0)[1...].map(UInt8.init) }
    if tagged {
      for (key, value) in VCPLevelsTags.session { CVBufferSetAttachment(buffer, key, value, .shouldPropagate) }
    }
    return buffer
  }

  static func values(of buffer: CVPixelBuffer) -> [[Int]] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let scale = CVPixelBufferGetWidth(buffer) / width
    guard CVPixelBufferIsPlanar(buffer) else {
      let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      return colours.indices.map { index in
        let (x, y) = center(of: index, scale: scale)
        let pixel = bytes + y * stride + x * 4
        return [Int(pixel[2]), Int(pixel[1]), Int(pixel[0])]
      }
    }

    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    let shift = CVPixelBufferGetWidthOfPlane(buffer, 1) < CVPixelBufferGetWidthOfPlane(buffer, 0) ? 1 : 0
    return colours.indices.map { index in
      let (x, y) = center(of: index, scale: scale)
      let pair = chroma + (y >> shift) * chromaStride + (x >> shift) * 2
      return [Int(luma[y * lumaStride + x]), Int(pair[0]), Int(pair[1])]
    }
  }

  static func center(of index: Int, scale: Int = 1) -> (x: Int, y: Int) {
    ((index % columns * patch + patch / 2) * scale, (index / columns * patch + patch / 2) * scale)
  }

  private static func make(_ format: OSType) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
    let status = CVPixelBufferCreate(nil, width, height, format, attributes, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw BenchUsageError(message: "no ramp buffer (\(status))") }

    return buffer
  }

  private static func fill(_ buffer: CVPixelBuffer, plane: Int?, _ pixel: (Colour) -> [UInt8]) throws {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = plane.map { CVPixelBufferGetBaseAddressOfPlane(buffer, $0) } ?? CVPixelBufferGetBaseAddress(buffer)
    let stride = plane.map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) } ?? CVPixelBufferGetBytesPerRow(buffer)
    guard let base = base?.assumingMemoryBound(to: UInt8.self) else { throw BenchUsageError(message: "no ramp plane") }

    let patches = colours.map(pixel)
    let blank = pixel((0, 0, 0))
    for y in 0..<height {
      for x in 0..<width {
        let index = y / patch * columns + x / patch
        let bytes = index < patches.count ? patches[index] : blank
        (base + y * stride + x * bytes.count).update(from: bytes, count: bytes.count)
      }
    }
  }
}
