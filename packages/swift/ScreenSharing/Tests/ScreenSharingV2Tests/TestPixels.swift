import CoreVideo
import ScreenSharing

enum TestPixels {
  static func frame(
    width: Int = 640, height: Int = 360, shade: UInt8, timestampNs: Int64, dirtyRects: [CGRect]? = nil
  ) throws
    -> ScreenSharingVideoFrame
  {
    try frame(width: width, height: height, shades: [shade], timestampNs: timestampNs, dirtyRects: dirtyRects)
  }

  static func frame(
    width: Int = 640, height: Int = 360, shades: [UInt8], timestampNs: Int64, dirtyRects: [CGRect]? = nil
  ) throws -> ScreenSharingVideoFrame {
    ScreenSharingVideoFrame(
      pixelBuffer: try buffer(width: width, height: height, shades: shades), timestampNs: timestampNs,
      dirtyRects: dirtyRects)
  }

  static func luma(of buffer: CVPixelBuffer, row: Int, column: Int) -> UInt8 {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    return base[row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + column]
  }

  private static func buffer(width: Int, height: Int, shades: [UInt8]) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
    CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
    guard let buffer else { throw ScreenSharingError.unavailable("No pixel buffer.") }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    for row in 0..<height { memset(luma + row * stride, Int32(shades[row * shades.count / height]), stride) }
    let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
    memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
    return buffer
  }
}
