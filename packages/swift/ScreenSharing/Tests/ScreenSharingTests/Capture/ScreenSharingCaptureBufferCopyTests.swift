import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingCaptureBufferCopyTests {
  private func source(width: Int = 64) throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      nil, width, 64, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
    #expect(status == kCVReturnSuccess)
    let source = try #require(pixel)
    #expect(CVPixelBufferLockBaseAddress(source, []) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(source, []) }
    let bytes = try #require(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
    for y in 0..<64 {
      for x in 0..<width {
        let offset = y * CVPixelBufferGetBytesPerRow(source) + x * 4
        for (channel, value) in [UInt8(64), 128, 192, 255].enumerated() { bytes[offset + channel] = value }
      }
    }
    return source
  }

  @Test func keepsSixOutstandingCopiesThenReusesReleasedBuffers() throws {
    let copier = ScreenSharingCaptureBufferCopy()
    let source = try source()
    var held: [CVPixelBuffer] = []
    for _ in 0..<ScreenSharingCaptureBufferCopy.maximumBuffers { held.append(try #require(try copier.copy(source))) }
    #expect(try copier.copy(source) == nil)
    held.removeAll()
    #expect(try copier.copy(source) != nil)
  }

  @Test func preservesPixelsAndRecreatesPoolAfterSizeChange() throws {
    let copier = ScreenSharingCaptureBufferCopy()
    for width in [64, 128, 64] {
      let original = try source(width: width)
      let copied = try #require(try copier.copy(original))
      #expect(copied !== original)
      #expect(CVPixelBufferGetWidth(copied) == width)
      #expect(CVPixelBufferGetHeight(copied) == 64)
      #expect(CVPixelBufferGetPixelFormatType(copied) == kCVPixelFormatType_32BGRA)
      #expect(CVPixelBufferLockBaseAddress(copied, .readOnly) == kCVReturnSuccess)
      defer { CVPixelBufferUnlockBaseAddress(copied, .readOnly) }
      let bytes = try #require(CVPixelBufferGetBaseAddress(copied)).assumingMemoryBound(to: UInt8.self)
      #expect(Array(UnsafeBufferPointer(start: bytes, count: 4)) == [64, 128, 192, 255])
    }
  }
}
