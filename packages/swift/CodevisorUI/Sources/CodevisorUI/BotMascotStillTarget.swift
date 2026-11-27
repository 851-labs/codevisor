import CoreGraphics
import Foundation
import Metal
@preconcurrency import RiveRuntime

struct BotMascotStillTarget: @unchecked Sendable {
  enum Failure: Error {
    case noTexture
    case noImage
  }

  private static let bytesPerPixel = 4

  let texture: any MTLTexture
  private let buffer: any MTLBuffer
  private let side: Int

  init(side: Int, device: any MTLDevice) throws {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: MTLRiveColorPixelFormat(), width: side, height: side, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    guard let texture = device.makeTexture(descriptor: descriptor),
      let buffer = device.makeBuffer(length: side * side * Self.bytesPerPixel, options: .storageModeShared)
    else { throw Failure.noTexture }

    self.texture = texture
    self.buffer = buffer
    self.side = side
  }

  func copying(then done: @escaping @Sendable () -> Void) -> @Sendable (any MTLCommandBuffer) -> Void {
    { commands in
      encodeCopy(into: commands)
      commands.addCompletedHandler { _ in done() }
    }
  }

  func image(cropTo rect: CGRect) throws -> CGImage {
    guard let whole = wholeImage(), let cropped = whole.cropping(to: Self.pixelSquare(rect)) else {
      throw Failure.noImage
    }
    return cropped
  }

  private static func pixelSquare(_ rect: CGRect) -> CGRect {
    let side = rect.width.rounded()
    return CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: side, height: side)
  }

  private var bytesPerRow: Int { side * Self.bytesPerPixel }

  private func encodeCopy(into commands: any MTLCommandBuffer) {
    guard let blit = commands.makeBlitCommandEncoder() else { return }

    blit.copy(
      from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
      sourceSize: MTLSize(width: side, height: side, depth: 1),
      to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
      destinationBytesPerImage: bytesPerRow * side)
    blit.endEncoding()
  }

  private func wholeImage() -> CGImage? {
    let bytes = Data(bytes: buffer.contents(), count: bytesPerRow * side)
    guard let provider = CGDataProvider(data: bytes as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
      return nil
    }
    let info = CGBitmapInfo(
      rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    return CGImage(
      width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8 * Self.bytesPerPixel, bytesPerRow: bytesPerRow,
      space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}
