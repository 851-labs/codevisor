import CoreVideo
import MetalKit
import Testing

@testable import ScreenSharing

/// Where the remote screen lands inside the render target. The arithmetic is
/// checked on its own, and then end to end: a white frame is actually rendered
/// into a texture over a coloured clear, and the resulting pixels say where the
/// video and its letterbox bars are.
@MainActor
struct ScreenSharingMetalSurfaceTests {
  @Test func aVideoWiderThanTheDrawableIsBarredAboveAndBelow() {
    let viewport = ScreenSharingMetalEncoder.viewport(
      video: .init(width: 1920, height: 1080), target: .init(width: 640, height: 480))
    expect(viewport, originX: 0, originY: 60, width: 640, height: 360)
    #expect(viewport.znear == 0 && viewport.zfar == 1)
  }

  @Test func aVideoTallerThanTheDrawableIsBarredLeftAndRight() {
    let viewport = ScreenSharingMetalEncoder.viewport(
      video: .init(width: 768, height: 1024), target: .init(width: 1000, height: 1000))
    expect(viewport, originX: 125, originY: 0, width: 750, height: 1000)
  }

  @Test func aMatchingAspectRatioFillsTheDrawableExactly() {
    let viewport = ScreenSharingMetalEncoder.viewport(
      video: .init(width: 1920, height: 1080), target: .init(width: 3840, height: 2160))
    expect(viewport, originX: 0, originY: 0, width: 3840, height: 2160)
  }

  /// A window on a Retina display at an arbitrary width produces a scale that
  /// is not a round number; the bars must still be symmetric to the last bit.
  @Test(arguments: awkwardSizes)
  func theBarsAreSymmetricAtANonIntegralScale(video: CGSize, target: CGSize) {
    let viewport = ScreenSharingMetalEncoder.viewport(video: video, target: target)
    #expect(abs(viewport.originX * 2 + viewport.width - target.width) < 1e-9)
    #expect(abs(viewport.originY * 2 + viewport.height - target.height) < 1e-9)
    #expect(viewport.width <= target.width + 1e-9 && viewport.height <= target.height + 1e-9)
    // The fitted rectangle is the video scaled once, so it keeps the video's aspect ratio.
    #expect(abs(viewport.width * video.height - viewport.height * video.width) < 1e-6)
  }

  @Test func aSingleVideoPixelStillFitsTheDrawable() {
    let viewport = ScreenSharingMetalEncoder.viewport(
      video: .init(width: 1, height: 1), target: .init(width: 640, height: 480))
    expect(viewport, originX: 80, originY: 0, width: 480, height: 480)
  }

  /// A drawable can be measured before the view has any size. The viewport that
  /// comes back must be empty rather than negative or not-a-number.
  @Test func aCollapsedDrawableProducesAnEmptyViewport() {
    let viewport = ScreenSharingMetalEncoder.viewport(video: .init(width: 1920, height: 1080), target: .zero)
    #expect(viewport.originX == 0 && viewport.originY == 0)
    #expect(viewport.width == 0 && viewport.height == 0)
    #expect(viewport.width.isFinite && viewport.height.isFinite)
  }

  @Test func theRenderedFrameSitsInsideItsBarsAndNothingIsCommittedByTheEncoder() throws {
    let gpu = try GPUFixture()
    // 100 × 100 video into a 640 × 480 drawable: scaled by 4.8 to 480 × 480,
    // leaving 80-pixel bars on the left and right.
    let rendered = try gpu.render(video: .init(width: 100, height: 100), target: .init(width: 640, height: 480))
    #expect(rendered.isVideo(x: 320, y: 240))
    #expect(rendered.isVideo(x: 320, y: 2), "the video reaches the top edge")
    #expect(rendered.isVideo(x: 82, y: 240) && rendered.isVideo(x: 558, y: 240))
    #expect(rendered.isBar(x: 78, y: 240) && rendered.isBar(x: 562, y: 240))
    #expect(rendered.isBar(x: 0, y: 0) && rendered.isBar(x: 639, y: 479))
  }

  @Test func aWideFrameLeavesTheBarsAboveAndBelow() throws {
    let gpu = try GPUFixture()
    // 1920 × 1080 into 640 × 480: 640 × 360 with 60-pixel bars top and bottom.
    let rendered = try gpu.render(video: .init(width: 1920, height: 1080), target: .init(width: 640, height: 480))
    #expect(rendered.isVideo(x: 0, y: 240) && rendered.isVideo(x: 639, y: 240))
    #expect(rendered.isVideo(x: 320, y: 62) && rendered.isVideo(x: 320, y: 418))
    #expect(rendered.isBar(x: 320, y: 58) && rendered.isBar(x: 320, y: 422))
  }

  @Test func aResizeRedrawsTheCachedFrameAndStopsWithTheRenderer() throws {
    let mailbox = ScreenSharingFrameMailbox()
    let view = try ScreenSharingMetalView(mailbox: mailbox, metrics: ScreenSharingMetrics())
    defer { view.stop() }
    let buffer = try GPUFixture.pixelBuffer(width: 64, height: 64)
    mailbox.put(ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: 1, rtpTimestamp: 9))
    let first = try #require(view.coordinator.select())
    #expect(first.isNewFrame)
    let idle = view.coordinator.select()
    #expect(idle == nil, "with no new frame and no resize there is nothing to draw")

    view.mtkView(view, drawableSizeWillChange: .init(width: 800, height: 600))
    let redraw = try #require(view.coordinator.select())
    #expect(!redraw.isNewFrame)
    #expect(redraw.frame.rtpTimestamp == 9, "the cached frame is redrawn at the new size")

    view.stop()
    view.mtkView(view, drawableSizeWillChange: .init(width: 100, height: 100))
    let afterStop = view.coordinator.select()
    #expect(afterStop == nil)
  }
}

private let awkwardSizes: [(CGSize, CGSize)] = [
  (CGSize(width: 1512, height: 982), CGSize(width: 1333, height: 667)),
  (CGSize(width: 1366, height: 768), CGSize(width: 641, height: 481)),
  (CGSize(width: 3, height: 7), CGSize(width: 1000, height: 1000)),
]

/// Every viewport value carries the rounding of one division, so they are
/// compared far below a pixel rather than bit for bit.
private func expect(
  _ viewport: MTLViewport, originX: Double, originY: Double, width: Double, height: Double,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(abs(viewport.originX - originX) < 1e-9, sourceLocation: sourceLocation)
  #expect(abs(viewport.originY - originY) < 1e-9, sourceLocation: sourceLocation)
  #expect(abs(viewport.width - width) < 1e-9, sourceLocation: sourceLocation)
  #expect(abs(viewport.height - height) < 1e-9, sourceLocation: sourceLocation)
}

/// A real device, queue, encoder and off-screen render target. Metal is a
/// hard requirement of the viewer, so its absence is reported as a failure
/// here rather than passing a test that rendered nothing. The target is an
/// ordinary texture rather than a `CAMetalLayer` drawable: the drawable only
/// ever contributed its texture, and acquiring one needs a window server
/// session that a headless CI runner does not have.
@MainActor
private struct GPUFixture {
  let device: any MTLDevice
  let queue: any MTLCommandQueue
  let encoder: ScreenSharingMetalEncoder

  init() throws {
    device = try #require(MTLCreateSystemDefaultDevice(), "This machine has no Metal device to render with")
    queue = try #require(device.makeCommandQueue())
    encoder = try ScreenSharingMetalEncoder(
      device: device, commandQueue: queue,
      pipelines: .init(device: device, shader: ScreenSharingMetalView.shader))
  }

  /// Renders an all-white video of `video` size into a `target`-sized texture
  /// cleared to blue, and reads the result back.
  func render(video: CGSize, target: CGSize) throws -> Rendered {
    let buffer = try GPUFixture.pixelBuffer(width: Int(video.width), height: Int(video.height), fill: 0xFF)
    let frame = ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: 1)
    let textures = try #require(encoder.textures(for: frame))

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: Int(target.width), height: Int(target.height), mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    let surface = try #require(device.makeTexture(descriptor: descriptor), "the render target could not be allocated")
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = surface
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1)

    let encoded = try #require(encoder.encode(textures, into: pass, target: surface))
    #expect(encoded.buffer.status == .notEnqueued, "encoding never commits or presents")
    #expect(encoded.retained.textures.count == 1)
    encoded.buffer.commit()
    encoded.buffer.waitUntilCompleted()
    #expect(encoded.buffer.status == .completed)
    return try Rendered(texture: surface, device: device, queue: queue)
  }

  static func pixelBuffer(width: Int, height: Int, fill: UInt8 = 0) throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixel)
    let buffer = try #require(pixel, "pixel buffer creation failed (\(status))")
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(buffer) * height)
    }
    return buffer
  }
}

/// The render target's pixels, copied into CPU-readable memory so they can be
/// inspected.
private struct Rendered {
  private let pixels: [UInt8]
  private let width: Int

  init(texture: any MTLTexture, device: any MTLDevice, queue: any MTLCommandQueue) throws {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: texture.width, height: texture.height, mipmapped: false)
    // A discrete GPU does not write a `.shared` texture back anywhere the CPU
    // can see it: on a Radeon Pro 5300M the copy below lands as zeroes, with
    // the command buffer still reporting completion. `.managed` plus an
    // explicit synchronize is the readback that holds on unified and discrete
    // memory alike; iOS has unified memory and no managed mode.
    #if os(macOS)
      descriptor.storageMode = .managed
    #else
      descriptor.storageMode = .shared
    #endif
    let staging = try #require(device.makeTexture(descriptor: descriptor))
    let buffer = try #require(queue.makeCommandBuffer())
    let blit = try #require(buffer.makeBlitCommandEncoder())
    blit.copy(from: texture, to: staging)
    #if os(macOS)
      blit.synchronize(resource: staging)
    #endif
    blit.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    width = texture.width
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    bytes.withUnsafeMutableBytes { raw in
      staging.getBytes(
        raw.baseAddress!, bytesPerRow: texture.width * 4,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    }
    pixels = bytes
  }

  /// White: the all-white frame was drawn here.
  func isVideo(x: Int, y: Int) -> Bool { pixel(x, y) == (255, 255, 255) }
  /// The pass's blue clear color: a letterbox bar the video never covered.
  func isBar(x: Int, y: Int) -> Bool { pixel(x, y) == (255, 0, 0) }

  private func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    let offset = (y * width + x) * 4
    return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
  }
}
