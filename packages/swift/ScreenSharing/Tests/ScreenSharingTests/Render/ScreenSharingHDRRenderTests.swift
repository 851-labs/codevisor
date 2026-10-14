import CoreVideo
import MetalKit
import Testing

@testable import ScreenSharing

@MainActor
struct ScreenSharingHDRRenderTests {
  static func pq(_ nits: Double) -> Double {
    let y = pow(nits / 10000, 2610.0 / 16384)
    return pow((3424.0 / 4096 + 2413.0 / 128 * y) / (1 + 2392.0 / 128 * y), 2523.0 / 32)
  }

  @Test func planeRangesMapCodesToUnitLumaAndCentredChroma() {
    let video8 = ScreenSharingMetalEncoder.PlaneRange(dynamicRange: .standard, fullRange: false).uniform
    #expect(abs(video8.x - 16 / 255) < 1e-6 && abs(video8.y - 255 / 219) < 1e-5)
    #expect(abs(video8.z - 128 / 255) < 1e-6 && abs(video8.w - 255 / 224) < 1e-5)
    let full8 = ScreenSharingMetalEncoder.PlaneRange(dynamicRange: .standard, fullRange: true).uniform
    #expect(full8.x == 0 && abs(full8.y - 1) < 1e-6)
    let video10 = ScreenSharingMetalEncoder.PlaneRange(dynamicRange: .high, fullRange: false).uniform
    #expect(abs(video10.x - 4096 / 65535) < 1e-6)
    #expect(abs((940 * 64 / 65535 - video10.x) * video10.y - 1) < 1e-5, "video white is 1")
    #expect(abs((960 * 64 / 65535 - video10.z) * video10.w - 0.5) < 1e-5, "full chroma is 0.5")
  }

  @Test(arguments: [
    kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
  ])
  func pqFramesBecomeLinearLightWithSDRWhiteAtOne(format: OSType) throws {
    let gpu = try HDRFixture()
    for nits in [0.0, 100, 203, 1000] {
      let rendered = try gpu.render(
        HDRFixture.flat(format: format, luma: Self.pq(nits)),
        target: ScreenSharingMetalEncoder.highDynamicRangePixelFormat)
      let expected = nits / 100
      for channel in rendered {
        #expect(abs(channel - expected) <= max(0.002, expected * 0.015), "\(nits) nits: \(channel) for \(expected)")
      }
    }
  }

  @Test func sdrWhiteMeetsHDRAt100Nits() throws {
    let gpu = try HDRFixture()
    for channel in try gpu.render(HDRFixture.bgra(255), target: ScreenSharingMetalEncoder.highDynamicRangePixelFormat) {
      #expect(abs(channel - 1) < 0.002, "\(channel)")
    }
    let format = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
    for (nits, expected) in [(100.0, 1.0), (1000, 1), (0, 0)] {
      for channel in try gpu.render(HDRFixture.flat(format: format, luma: Self.pq(nits)), target: .bgra8Unorm) {
        #expect(abs(channel - expected) < 1.5 / 255, "\(nits) nits: \(channel * 255)")
      }
    }
  }

  @Test func theLetterboxColourIsLinearizedForTheHDRDrawable() {
    let linear = ScreenSharingMetalView.linear(MTLClearColorMake(1, 0.5, 0.025, 0.75))
    #expect(abs(linear.red - 1) < 1e-9 && abs(linear.green - 0.214) < 1e-3)
    #expect(abs(linear.blue - 0.025 / 12.92) < 1e-9 && linear.alpha == 0.75)
  }

  @Test func eightBitFramesStillRenderAsBefore() throws {
    let gpu = try HDRFixture()
    for channel in try gpu.render(HDRFixture.bgra(128), target: .bgra8Unorm) {
      #expect(abs(channel - 128 / 255) < 0.5 / 255)
    }
    let format = kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
    for channel in try gpu.render(HDRFixture.flat(format: format, luma: 1), target: .bgra8Unorm) {
      #expect(abs(channel - 1) < 1.5 / 255)
    }
  }

  #if os(macOS)
    @Test func theRenderWorkerSwitchesTheLayerToHighDynamicRangeAndBack() async throws {
      let gpu = try HDRFixture()
      let layer = CAMetalLayer()
      layer.device = gpu.device
      layer.pixelFormat = .bgra8Unorm
      let metrics = ScreenSharingMetrics()
      let worker = ScreenSharingMetalPreparer(
        layer: layer,
        encoder: try ScreenSharingMetalEncoder(
          device: gpu.device, commandQueue: gpu.queue,
          pipelines: .init(device: gpu.device, shader: ScreenSharingMetalView.shader)),
        metrics: metrics)
      func prepare(_ buffer: CVPixelBuffer) async {
        let request = ScreenSharingPreparationRequest(
          frame: ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: 1), isNewFrame: true,
          geometry: .init(clearColor: SIMD4(1, 1, 1, 1), drawableSize: CGSize(width: 8, height: 8)), queuedAtNs: 0,
          auditIdentity: nil)
        await withCheckedContinuation { continuation in worker.prepare(request) { _ in continuation.resume() } }
      }
      await prepare(try HDRFixture.flat(format: ScreenSharingDynamicRange.highCapturePixelFormat, luma: 0.5))
      #expect(layer.pixelFormat == ScreenSharingMetalEncoder.highDynamicRangePixelFormat)
      #expect(layer.colorspace?.name == CGColorSpace.extendedLinearDisplayP3)
      #expect(metrics.label("renderDynamicRange") == ScreenSharingDynamicRange.high.rawValue)
      await prepare(try HDRFixture.bgra(128))
      #expect(layer.pixelFormat == .bgra8Unorm && layer.colorspace == nil)
      #expect(metrics.label("renderDynamicRange") == ScreenSharingDynamicRange.standard.rawValue)
    }
  #endif
}

@MainActor
private struct HDRFixture {
  let device: any MTLDevice
  let queue: any MTLCommandQueue
  let encoder: ScreenSharingMetalEncoder

  init() throws {
    device = try #require(MTLCreateSystemDefaultDevice(), "This machine has no Metal device to render with")
    queue = try #require(device.makeCommandQueue())
    encoder = try ScreenSharingMetalEncoder(
      device: device, commandQueue: queue, pipelines: .init(device: device, shader: ScreenSharingMetalView.shader))
  }

  func render(_ buffer: CVPixelBuffer, target format: MTLPixelFormat) throws -> [Double] {
    let textures = try #require(encoder.textures(for: ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: 1)))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: format, width: 8, height: 8, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .managed
    let surface = try #require(device.makeTexture(descriptor: descriptor))
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = surface
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    let encoded = try #require(encoder.encode(textures, into: pass, target: surface))
    let blit = try #require(encoded.buffer.makeBlitCommandEncoder())
    blit.synchronize(resource: surface)
    blit.endEncoding()
    encoded.buffer.commit()
    encoded.buffer.waitUntilCompleted()
    if format == .bgra8Unorm {
      var word: UInt32 = 0
      surface.getBytes(&word, bytesPerRow: 32, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
      return [16, 8, 0].map { Double((word >> $0) & 0xff) / 255 }
    }
    var halves = [Float16](repeating: 0, count: 4)
    surface.getBytes(&halves, bytesPerRow: 64, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
    return halves.prefix(3).map { Double($0) }
  }

  static func attributes() -> CFDictionary {
    [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
      as CFDictionary
  }

  static func flat(format: OSType, luma: Double) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    CVPixelBufferCreate(nil, 8, 8, format, attributes(), &created)
    let buffer = try #require(created)
    let range = ScreenSharingMetalEncoder.PlaneRange(
      dynamicRange: ScreenSharingDynamicRange(pixelFormat: format),
      fullRange: ScreenSharingMetalEncoder.fullRangePixelFormats.contains(format))
    let wide = range.dynamicRange == .high
    let maximum = wide ? 1023.0 : 255.0
    let (black, span) = range.fullRange ? (0.0, maximum) : ((maximum + 1) / 16, (maximum + 1) * 219 / 256)
    let y = Int((black + luma * span).rounded())
    let c = Int((maximum + 1) / 2)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<2 {
      let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
      let samples = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
      for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
        let line = base + row * stride
        for index in 0..<samples {
          let code = plane == 0 ? y : c
          if wide {
            line.assumingMemoryBound(to: UInt16.self)[index] = UInt16(code << 6)
          } else {
            line.assumingMemoryBound(to: UInt8.self)[index] = UInt8(code)
          }
        }
      }
    }
    return buffer
  }

  static func bgra(_ value: UInt8) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, attributes(), &created)
    let buffer = try #require(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    memset(CVPixelBufferGetBaseAddress(buffer), Int32(value), CVPixelBufferGetBytesPerRow(buffer) * 8)
    return buffer
  }
}
