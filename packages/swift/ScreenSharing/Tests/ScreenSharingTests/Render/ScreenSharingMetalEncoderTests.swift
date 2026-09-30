import CoreVideo
import Metal
import Testing
@testable import ScreenSharing

/// The encoder's pixel-format gate and plane binding, without a drawable: a
/// decoder's biplanar output and a framebuffer backend's BGRA output both bind,
/// anything else is refused before any GPU work is queued.
@MainActor
struct ScreenSharingMetalEncoderTests {
  @Test func bgraBindsOnePlaneOnItsOwnPipeline() throws {
    let encoder = try makeEncoder()
    let textures = try #require(encoder.textures(for: frame(kCVPixelFormatType_32BGRA)))
    guard case .bgra(let plane) = textures.planes else { Issue.record("Expected a BGRA plane"); return }
    #expect(CVMetalTextureGetTexture(plane)?.pixelFormat == .bgra8Unorm)
    #expect(textures.retained.count == 1)
  }

  @Test(arguments: [
    (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, false), (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, true),
    (kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, false), (kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, true),
    (kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, false), (kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, true),
    (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, false),
  ])
  func biplanarBindsLumaAndChromaWithItsRange(format: OSType, fullRange: Bool) throws {
    let encoder = try makeEncoder()
    let textures = try #require(encoder.textures(for: frame(format)))
    guard case .biplanar(let y, let uv, let range) = textures.planes else {
      Issue.record("Expected biplanar planes"); return
    }
    // 10-bit planes (HDR, 851-2380) are bound as 16-bit normalized samples.
    let wide = ScreenSharingDynamicRange(pixelFormat: format) == .high
    #expect(CVMetalTextureGetTexture(y)?.pixelFormat == (wide ? .r16Unorm : .r8Unorm))
    #expect(CVMetalTextureGetTexture(uv)?.pixelFormat == (wide ? .rg16Unorm : .rg8Unorm))
    #expect(range.fullRange == fullRange && range.dynamicRange == (wide ? .high : .standard))
    #expect(textures.dynamicRange == range.dynamicRange)
    #expect(textures.retained.count == 2)
  }

  @Test func unsupportedLayoutsAreRefusedBeforeAnyBinding() throws {
    let encoder = try makeEncoder()
    #expect(encoder.textures(for: frame(kCVPixelFormatType_422YpCbCr8)) == nil)
    #expect(encoder.textures(for: frame(kCVPixelFormatType_32ARGB)) == nil)
  }

  private func makeEncoder() throws -> ScreenSharingMetalEncoder {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    return try ScreenSharingMetalEncoder(
      device: device, commandQueue: queue,
      pipelines: .init(device: device, shader: ScreenSharingMetalView.shader))
  }

  private func frame(_ format: OSType) -> ScreenSharingVideoFrame {
    var pixel: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    let status = CVPixelBufferCreate(nil, 64, 64, format, attributes as CFDictionary, &pixel)
    precondition(status == kCVReturnSuccess && pixel != nil, "Pixel buffer creation failed (\(status))")
    return ScreenSharingVideoFrame(pixelBuffer: pixel!, timestampNs: 1)
  }
}
