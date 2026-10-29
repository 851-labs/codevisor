import Metal

public final class BenchTextureHasher: Sendable {
  public static let maximumInFlight = 4

  private let device: any MTLDevice
  private let buffers = MetalRecycler<any MTLBuffer>()
  private let canvas: BenchSceneCanvas

  public init(device: any MTLDevice, canvas: BenchSceneCanvas) {
    self.device = device
    self.canvas = canvas
  }

  public func hash(
    _ texture: any MTLTexture, commandBuffer: any MTLCommandBuffer, completion: @escaping @Sendable (String) -> Void
  ) throws -> Bool {
    let bytesPerRow = canvas.pixelWidth * 4
    guard
      let buffer = try buffers.take(
        orMake: { try makeBuffer(length: bytesPerRow * canvas.pixelHeight) }, limit: Self.maximumInFlight)
    else { return false }

    try copy(texture, into: buffer, bytesPerRow: bytesPerRow, commandBuffer: commandBuffer)
    let canvas = canvas
    let lent = UncheckedBuffer(buffer: buffer)
    commandBuffer.addCompletedHandler { _ in
      completion(
        BenchPixelHash.bgra(
          lent.buffer.contents(), width: canvas.pixelWidth, height: canvas.pixelHeight, bytesPerRow: bytesPerRow))
    }
    buffers.recycle(buffer, after: commandBuffer)
    return true
  }

  private func copy(
    _ texture: any MTLTexture, into buffer: any MTLBuffer, bytesPerRow: Int, commandBuffer: any MTLCommandBuffer
  ) throws {
    guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw BenchSceneError.encoderUnavailable }

    blit.copy(
      from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: MTLSize(width: canvas.pixelWidth, height: canvas.pixelHeight, depth: 1), to: buffer,
      destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: buffer.length)
    blit.endEncoding()
  }

  private func makeBuffer(length: Int) throws -> any MTLBuffer {
    guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
      throw BenchSceneError.textureUnavailable
    }

    return buffer
  }
}

private struct UncheckedBuffer: @unchecked Sendable {
  let buffer: any MTLBuffer
}
