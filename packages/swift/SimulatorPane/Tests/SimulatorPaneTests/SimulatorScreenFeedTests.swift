import CoreVideo
import Testing

@testable import SimulatorPane

@Suite struct SimulatorScreenFeedTests {
  private static func frame(_ format: OSType, luma: UInt16) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 64, 48, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    let frame = try #require(buffer)
    CVPixelBufferLockBaseAddress(frame, [])
    defer { CVPixelBufferUnlockBaseAddress(frame, []) }
    let base = try #require(CVPixelBufferGetBaseAddressOfPlane(frame, 0))
    let stride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
    for row in 0..<CVPixelBufferGetHeightOfPlane(frame, 0) {
      let line = base.advanced(by: row * stride)
      for column in 0..<CVPixelBufferGetWidthOfPlane(frame, 0) {
        if format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
          line.storeBytes(of: luma << 8, toByteOffset: column * 2, as: UInt16.self)
        } else {
          line.storeBytes(of: UInt8(luma), toByteOffset: column, as: UInt8.self)
        }
      }
    }
    return frame
  }

  @Test func measuresLumaInEightAndTenBitFrames() throws {
    let black = try Self.frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, luma: 16)
    let lit = try Self.frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, luma: 140)
    let wide = try Self.frame(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, luma: 140)
    #expect(SimulatorScreenFeed.brightness(black) == 16)
    #expect(try #require(SimulatorScreenFeed.brightness(black)) < SimulatorScreenFeed.lit)
    #expect(SimulatorScreenFeed.brightness(lit) == 140)
    #expect(SimulatorScreenFeed.brightness(wide) == 140)
  }

  @Test func leavesOutFormatsWithoutALumaPlane() throws {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer)
    #expect(SimulatorScreenFeed.brightness(try #require(buffer)) == nil)
  }
}
