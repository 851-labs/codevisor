import CoreVideo
import Foundation
@preconcurrency import Metal

final class ScreenSharingV2TileBlitter: @unchecked Sendable {
  struct Copy {
    let source: CVPixelBuffer
    let sourceRow: Int
    let targetRow: Int
    let rows: Int
  }

  private let queue: any MTLCommandQueue
  private let cache: CVMetalTextureCache

  init?() {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }

    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }

    self.queue = queue
    self.cache = cache
  }

  func copy(_ copies: [Copy], into target: CVPixelBuffer) -> Bool {
    let format = CVPixelBufferGetPixelFormatType(target)
    guard let formats = Self.planeFormats[format],
      copies.allSatisfy({ CVPixelBufferGetPixelFormatType($0.source) == format }),
      let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder()
    else { return false }

    var retained: [CVMetalTexture] = []
    for (index, pixelFormat) in formats.enumerated() {
      guard let to = texture(target, plane: index, format: pixelFormat, retaining: &retained) else {
        blit.endEncoding()
        return false
      }

      for copy in copies {
        guard let from = texture(copy.source, plane: index, format: pixelFormat, retaining: &retained) else {
          blit.endEncoding()
          return false
        }

        encode(copy, plane: index, from: from, to: to, target: target, into: blit)
      }
    }
    blit.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    return withExtendedLifetime(retained) { buffer.status == .completed }
  }

  private func encode(
    _ copy: Copy, plane index: Int, from: any MTLTexture, to: any MTLTexture, target: CVPixelBuffer,
    into blit: any MTLBlitCommandEncoder
  ) {
    let sourceRow = copy.sourceRow * from.height / CVPixelBufferGetHeight(copy.source)
    let targetRow = copy.targetRow * to.height / CVPixelBufferGetHeight(target)
    let rows = min(
      copy.rows * from.height / CVPixelBufferGetHeight(copy.source), from.height - sourceRow, to.height - targetRow)
    guard rows > 0 else { return }

    blit.copy(
      from: from, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: sourceRow, z: 0),
      sourceSize: MTLSize(width: min(from.width, to.width), height: rows, depth: 1), to: to, destinationSlice: 0,
      destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: targetRow, z: 0))
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
