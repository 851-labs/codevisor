import CoreVideo
import Foundation
@preconcurrency import Metal

final class ScreenSharingV2TileBlitter: @unchecked Sendable {
  private let queue: any MTLCommandQueue
  private let cache: CVMetalTextureCache

  init?() {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }

    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }

    self.queue = queue
    self.cache = cache
  }

  func copy(rows: Range<Int>, of height: Int, from source: CVPixelBuffer, to target: CVPixelBuffer) -> Bool {
    guard let formats = Self.planeFormats[CVPixelBufferGetPixelFormatType(source)],
      let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder()
    else { return false }

    var retained: [CVMetalTexture] = []
    for (index, format) in formats.enumerated() {
      let plane = ScreenSharingV2PixelPlane(index: CVPixelBufferIsPlanar(source) ? index : nil)
      guard let from = texture(source, plane: index, format: format, retaining: &retained),
        let to = texture(target, plane: index, format: format, retaining: &retained)
      else {
        blit.endEncoding()
        return false
      }

      let span = plane.rows(rows, of: source, height: height)
      let count = min(span.count, to.height)
      blit.copy(
        from: from, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: span.lowerBound, z: 0),
        sourceSize: MTLSize(width: min(from.width, to.width), height: count, depth: 1), to: to, destinationSlice: 0,
        destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    }
    blit.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    return withExtendedLifetime(retained) { buffer.status == .completed }
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
    kCVPixelFormatType_32BGRA: [.bgra8Unorm],
  ]
}
