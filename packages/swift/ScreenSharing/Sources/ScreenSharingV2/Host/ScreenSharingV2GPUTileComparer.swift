import CoreVideo
import Foundation
@preconcurrency import Metal

final class ScreenSharingV2GPUTileComparer: @unchecked Sendable {
  private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void tileDiffers(
      texture2d<float, access::read> previous [[texture(0)]], texture2d<float, access::read> current [[texture(1)]],
      device atomic_uint *changed [[buffer(0)]], constant uint &tileRows [[buffer(1)]],
      uint2 position [[thread_position_in_grid]]) {
      if (position.x >= current.get_width() || position.y >= current.get_height()) return;
      if (any(previous.read(position) != current.read(position))) {
        atomic_store_explicit(&changed[position.y / tileRows], 1, memory_order_relaxed);
      }
    }
    """

  private let queue: any MTLCommandQueue
  private let pipeline: any MTLComputePipelineState
  private let cache: CVMetalTextureCache
  private let flags: any MTLBuffer

  init?() {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let library = try? device.makeLibrary(source: Self.source, options: nil),
      let function = library.makeFunction(name: "tileDiffers"),
      let pipeline = try? device.makeComputePipelineState(function: function),
      let flags = device.makeBuffer(
        length: ScreenSharingV2TileLayout.maximumCount * MemoryLayout<UInt32>.stride, options: .storageModeShared)
    else { return nil }

    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }

    self.queue = queue
    self.pipeline = pipeline
    self.cache = cache
    self.flags = flags
  }

  func changed(
    _ tiles: Set<Int>, of layout: ScreenSharingV2TileLayout, from previous: CVPixelBuffer, to current: CVPixelBuffer
  ) -> Set<Int>? {
    guard let formats = Self.planeFormats[CVPixelBufferGetPixelFormatType(current)],
      CVPixelBufferGetPixelFormatType(previous) == CVPixelBufferGetPixelFormatType(current),
      let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder()
    else { return nil }

    memset(flags.contents(), 0, flags.length)
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(flags, offset: 0, index: 0)
    var retained: [CVMetalTexture] = []
    for (plane, format) in formats.enumerated() {
      guard let old = texture(previous, plane: plane, format: format, retaining: &retained),
        let new = texture(current, plane: plane, format: format, retaining: &retained)
      else {
        encoder.endEncoding()
        return nil
      }

      var tileRows = UInt32(max(1, layout.tileHeight * new.height / layout.height))
      encoder.setTexture(old, index: 0)
      encoder.setTexture(new, index: 1)
      encoder.setBytes(&tileRows, length: MemoryLayout<UInt32>.size, index: 1)
      encoder.dispatchThreads(
        MTLSize(width: new.width, height: new.height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 32, height: pipeline.maxTotalThreadsPerThreadgroup / 32, depth: 1))
    }
    encoder.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    let completed = withExtendedLifetime(retained) { buffer.status == .completed }
    CVMetalTextureCacheFlush(cache, 0)
    guard completed else { return nil }

    let changed = flags.contents().bindMemory(to: UInt32.self, capacity: ScreenSharingV2TileLayout.maximumCount)
    return tiles.filter { $0 < ScreenSharingV2TileLayout.maximumCount && changed[$0] != 0 }
  }

  private func texture(
    _ pixels: CVPixelBuffer, plane: Int, format: MTLPixelFormat, retaining retained: inout [CVMetalTexture]
  ) -> (any MTLTexture)? {
    let planar = CVPixelBufferIsPlanar(pixels)
    let width = planar ? CVPixelBufferGetWidthOfPlane(pixels, plane) : CVPixelBufferGetWidth(pixels)
    let height = planar ? CVPixelBufferGetHeightOfPlane(pixels, plane) : CVPixelBufferGetHeight(pixels)
    var texture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      nil, cache, pixels, nil, format, width, height, plane, &texture)
    guard status == kCVReturnSuccess, let texture, let metal = CVMetalTextureGetTexture(texture) else { return nil }

    retained.append(texture)
    return metal
  }

  private static let planeFormats: [OSType: [MTLPixelFormat]] = [
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: [.r8Unorm, .rg8Unorm],
    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: [.r8Unorm, .rg8Unorm],
    kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: [.r8Unorm, .rg8Unorm],
    kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: [.r8Unorm, .rg8Unorm],
    kCVPixelFormatType_32BGRA: [.bgra8Unorm],
  ]
}
