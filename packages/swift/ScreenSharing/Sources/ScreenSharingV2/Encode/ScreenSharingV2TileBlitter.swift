import CoreVideo
import Foundation
@preconcurrency import Metal

final class ScreenSharingV2TileBlitter: @unchecked Sendable {
  struct Copy {
    let source: CVPixelBuffer
    let target: CVPixelBuffer
    let sourceRow: Int
    let targetRow: Int
    let rows: Int
  }

  private let queue: any MTLCommandQueue
  private let textures: ScreenSharingV2MetalTextures

  init?() {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let textures = try? ScreenSharingV2MetalTextures(device: device)
    else { return nil }

    self.queue = queue
    self.textures = textures
  }

  func copy(_ copies: [Copy]) -> Bool {
    guard !copies.isEmpty,
      let format = copies.first.map({ CVPixelBufferGetPixelFormatType($0.source) }),
      copies.allSatisfy({
        CVPixelBufferGetPixelFormatType($0.source) == format && CVPixelBufferGetPixelFormatType($0.target) == format
      }),
      let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder()
    else { return false }

    var retained: [CVMetalTexture] = []
    for copy in copies {
      guard let from = try? textures.planes(of: copy.source, retaining: &retained),
        let to = try? textures.planes(of: copy.target, retaining: &retained)
      else {
        blit.endEncoding()
        return false
      }

      for (from, to) in zip(from, to) { encode(copy, from: from, to: to, into: blit) }
    }
    blit.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    let completed = withExtendedLifetime(retained) { buffer.status == .completed }
    textures.flush()
    return completed
  }

  private func encode(_ copy: Copy, from: any MTLTexture, to: any MTLTexture, into blit: any MTLBlitCommandEncoder) {
    let target = copy.target
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
}
