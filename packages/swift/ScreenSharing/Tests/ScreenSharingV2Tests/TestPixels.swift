import CoreVideo
import ScreenSharing

enum TestPixels {
  static func frame(
    width: Int = 640, height: Int = 360, shade: UInt8, timestampNs: Int64
  ) throws
    -> ScreenSharingVideoFrame
  {
    ScreenSharingVideoFrame(
      pixelBuffer: try buffer(width: width, height: height, shade: shade), timestampNs: timestampNs)
  }

  private static func buffer(width: Int, height: Int, shade: UInt8) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
    CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
    guard let buffer else { throw ScreenSharingError.unavailable("No pixel buffer.") }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
      let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
      let size = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
      memset(base, Int32(plane == 0 ? shade : 128), size)
    }
    return buffer
  }
}
